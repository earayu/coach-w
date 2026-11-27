"""A stronger text model writes what the coach says for a cue; the realtime model speaks it.

Chosen per session from the phone's developer settings (spec 4.2.1). The realtime flash model
reads numbers without thinking about them (COCH-15: it praised a bike ride's 4'22" "kilometre"
at 72 steps a minute); a text model applies common sense before the coach opens its mouth.
Timing is still the brain's; safety cues skip the writer so they are said at once.
"""

from __future__ import annotations

import logging
import re
from collections.abc import Awaitable, Callable, Iterable, Sequence
from typing import Any

from coachw.agent.transcript import classify
from coachw.coach.brain import PRIORITY_TONE, CoachBrain, Delivery
from coachw.protocol import CuePriority

logger = logging.getLogger("coachw.agent")

Write = Callable[[str, str], Awaitable[str | None]]

SYSTEM = """\
你是语音运动教练 coach-w 的大脑，用户正在运动，戴着耳机听你说话。\
根据教练提示，写出教练现在要说的话。

要求：
- 一两句中文口语，像一个懂运动生理和训练常识的真人教练，简短，适合边喘气边听。
- 只用教练提示和运动状态里出现的数字，不要编数字，不要估算。
- 先用常识判断这些数据合不合理、和用户正在做的运动对不对得上。\
手表上选的运动可能和用户实际在做的不一样，传感器也会出错。说不通就直说哪里不对、猜一猜可能的原因、问用户，不要夸。
- 结合最近的对话，不要重复刚说过的话；已经播报过的公里分段、掉速提醒或问过的问题绝不重复。
- 如果最近几句全是教练在说话、用户没有回应，且没有重要新变化，\
就只输出 SKIP，不要反复追问"你是不是在走路""感觉怎么样"。
- 只输出要说的话本身，不要引号，不要解释，不要 markdown。
- 教练提示让你自己判断要不要说时，没什么值得说的就只输出 SKIP。不要为了说而说，\
也不要重复最近几分钟说过的内容。
"""

SKIP = "SKIP"

SAY = "【教练提示】把下面这句话自然地说给用户听，意思和数字都不要改，也不要补充：\n{text}"

HISTORY_LINES = 8

_NUMBER = re.compile(r"\d+(?:\.\d+)?")
_CLOCK = re.compile(r"现在时间\s*\d{2}:\d{2}:\d{2}")
_PUNCT = re.compile(r"[\s\W_]+")


def _same_line(a: str, b: str) -> bool:
    na, nb = _PUNCT.sub("", a), _PUNCT.sub("", b)
    return bool(na) and na == nb


def conversation_of(items: Iterable[Any], limit: int = HISTORY_LINES) -> list[tuple[str, str]]:
    """The last things the athlete and the coach said in a chat context, without system prompts."""
    if limit <= 0:
        return []
    said: list[tuple[str, str]] = []
    for item in items:
        if getattr(item, "type", None) != "message":
            continue
        text = getattr(item, "text_content", None) or ""
        if (kind := classify(getattr(item, "role", None), text)) in ("user", "coach") and text:
            said.append((kind, text))
    return said[-limit:]


def numbers_in(text: str) -> set[str]:
    return set(_NUMBER.findall(text))


class CueWriter:
    def __init__(
        self,
        brain: CoachBrain,
        write: Write,
        history: Callable[[], Sequence[tuple[str, str]]] = lambda: (),
        close: Callable[[], Awaitable[None]] | None = None,
    ) -> None:
        self.brain = brain
        self._write = write
        self._history = history
        self._close = close

    async def aclose(self) -> None:
        if self._close is not None:
            await self._close()

    def prompt(self, delivery: Delivery) -> str:
        cue = delivery.cue
        label = self.brain.profile.label if self.brain.profile else "运动"
        lines = [f"用户正在做：{label}（手表上选的运动）"]
        if said := self._history():
            lines.append("最近的对话：")
            lines += [f"{'用户' if kind == 'user' else '教练'}：{text}" for kind, text in said]
        if status := self.brain.status_summary():
            lines.append(f"运动状态：{status}")
        lines.append(f"教练提示：{cue.event.facts}")
        lines.append(f"语气：{PRIORITY_TONE[cue.priority]}")
        return "\n".join(lines)

    async def instructions_for(self, delivery: Delivery) -> str | None:
        """What to hand the realtime model: the written line, or the plain cue as a fallback.

        None for a wake-up (`delivery.optional`) with nothing worth saying, or whose line could
        not be used: a wake-up has no plain cue to fall back on (spec 4.2.2)."""
        if delivery.cue.priority is CuePriority.EMERGENCY:
            return delivery.instructions
        fallback = None if delivery.optional else delivery.instructions
        prompt = self.prompt(delivery)
        text = await self._write(SYSTEM, prompt)
        if not text:
            return fallback
        # AGENTS.md 2: every number must come from the facts the coach system gave
        if invented := numbers_in(text) - numbers_in(_CLOCK.sub("", prompt)):
            logger.info("writer added %d numbers of its own; using the plain cue", len(invented))
            return fallback
        cleaned = text.strip().strip('"“”「」').strip()
        if not cleaned or cleaned.upper().startswith(SKIP):
            return fallback
        # Never repeat the coach's immediately preceding line verbatim.
        last_coach = next(
            (line for kind, line in reversed(self._history()) if kind == "coach"), None
        )
        if last_coach is not None and _same_line(cleaned, last_coach):
            logger.info("writer repeated the last coach line; dropping duplicate")
            return None if delivery.optional else fallback
        return SAY.format(text=cleaned)
