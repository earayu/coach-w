"""Deterministic capture of product feedback spoken by the athlete (COCH-22).

On 2026-11-26 the athlete spoke several explicit "product improvement" notes; the realtime model
agreed out loud ("noted") without calling `note_feedback`, so nothing reached `feedback/*.jsonl`.
Just like `VoiceStart` and `control_heard`, catching clear feedback markers directly on final
athlete transcripts guarantees feedback is never lost; `AthleteMemory.note_feedback` deduplicates
if the model also calls the tool.
"""

from __future__ import annotations

import re

MARKER = re.compile(
    r"产品改进点|产品改进|改进点|产品意见|产品建议|产品反馈"
    r"|反馈给开发|给开发(?:团队)?(?:提|反馈|说)"
    r"|记(?:一)?(?:下|个)?(?:产品)?(?:改进|意见|建议|反馈|bug|问题)",
    re.I,
)
# Questions or negations about feedback, not actual feedback to record.
HOLD = re.compile(
    r"(?:没(?:有)?(?:什么)?|不是|不算)(?:产品)?(?:改进|意见|建议|反馈)"
    r"|(?:记下来?|记)了(?:吗|没|么)"
)
RETROSPECTIVE = re.compile(r"这(?:是|算|也算)|刚才|刚刚|前面|上面|那个")
PROSPECTIVE = re.compile(r"我要|我想|下面|接下来|提一个|说一个|再记")
FILLER = re.compile(
    r"^(?:嗯|啊|哦|喔|好|好的|对|是的|行|可以|是|那|那个|就是|然后|还有|帮我|帮忙|请|一下|一个|这个|这是)+$"
)
_STRIP_FILLER = re.compile(
    r"[\s\W_]+|这(?:是|算|也算)|刚才|刚刚|我要|我想|帮我|帮忙|请|一下|一个|提|说|有|个|的|了|吧|呢|啊|哦|嗯"
)

RECENT_WINDOW_S = 25.0
AWAIT_FOLLOWUP_S = 25.0
MIN_SUBSTANCE = 6
MIN_FOLLOWUP = 4


def _substance(text: str) -> str:
    without_marker = MARKER.sub("", text)
    return _STRIP_FILLER.sub("", without_marker)


def _word_chars(text: str) -> str:
    return re.sub(r"[\s\W_]+", "", text)


class FeedbackCatcher:
    """Inspects each final athlete utterance and returns feedback text to persist, if any."""

    def __init__(self) -> None:
        self._recent: list[tuple[float, str]] = []
        self._awaiting_until: float = float("-inf")
        self._last_saved: str | None = None

    def heard(self, text: str, now: float) -> str | None:
        cleaned = text.strip()
        words = _word_chars(cleaned)
        if not words:
            return None
        self._recent = [(ts, t) for ts, t in self._recent if now - ts <= RECENT_WINDOW_S]

        # Follow-up utterance right after a bare marker ("我提一个产品改进点" -> "...").
        if now <= self._awaiting_until and not MARKER.search(cleaned):
            if len(words) >= MIN_FOLLOWUP and not FILLER.match(words):
                self._awaiting_until = float("-inf")
                self._last_saved = cleaned
                return cleaned
            return None

        if MARKER.search(cleaned):
            if HOLD.search(cleaned):
                return None
            if len(_substance(cleaned)) >= MIN_SUBSTANCE:
                self._awaiting_until = float("-inf")
                self._last_saved = cleaned
                return cleaned
            # Bare marker: either points back to what was just said, or introduces the next line.
            recent = self._latest_substantive()
            if RETROSPECTIVE.search(cleaned) and recent is not None:
                self._awaiting_until = float("-inf")
                self._last_saved = recent
                return recent
            self._awaiting_until = now + AWAIT_FOLLOWUP_S
            if recent is not None and not PROSPECTIVE.search(cleaned):
                self._last_saved = recent
                return recent
            return None

        if len(words) >= MIN_SUBSTANCE and not FILLER.match(words):
            self._recent.append((now, cleaned))
            self._recent = self._recent[-3:]
        return None

    def _latest_substantive(self) -> str | None:
        for _, text in reversed(self._recent):
            if text != self._last_saved:
                return text
        return None
