"""Keeps the coach from answering turns nobody said, and from saying the model's placeholders.

Qwen's server VAD ends a "turn" on wind, traffic or breathing too. The transcript then arrives
empty, but Qwen has already started a reply to it: the coach said "好，收到" or repeated its last
answer while the athlete said nothing (COCH-22, both times after a 0-character turn). Qwen also
sometimes answers with a placeholder such as "[ERROR: Failed to create agent for this item]" or
"[工具调用]" instead of a reply; the athlete's question then went unanswered.
"""

from __future__ import annotations

import logging
import re
import time
from collections.abc import Callable
from typing import Any

from coachw.agent.transcript import PLACEHOLDER

logger = logging.getLogger("coachw.agent")

_NOT_WORDS = re.compile(r"[\s\W_]+")

# A reply Qwen started on its own this soon before an empty transcript answers that turn.
AUTO_REPLY_WINDOW_S = 6.0
# An empty transcript can also arrive first: the next reply Qwen starts this soon after it is
# still the answer to nothing.
DROP_WINDOW_S = 3.0
# Asking again after a placeholder reply, at most this often.
RETRY_EVERY_S = 20.0

RETRY = "【教练提示】你刚才的回答没有发出去。直接回答用户上一句话，不要提到出错。"


def is_placeholder(text: str) -> bool:
    return bool(PLACEHOLDER.match(text))


def is_empty_turn(text: str) -> bool:
    """A transcript without a single word: noise the VAD took for speech."""
    return not _NOT_WORDS.sub("", text)


class TurnGuard:
    def __init__(self, session: Any, clock: Callable[[], float] = time.monotonic) -> None:
        self.session = session
        self.clock = clock
        self._auto: tuple[Any, float] | None = None
        self._drop_until = float("-inf")
        self._coach_cut_off = False
        self._retried_at = float("-inf")
        self.dropped = 0

    def attach(self) -> None:
        self.session.on("speech_created", self.on_speech_created)
        self.session.on("user_input_transcribed", self.on_user_input)
        self.session.on("conversation_item_added", self.on_item_added)

    def on_speech_created(self, ev: Any) -> None:
        # replies the coach system asked for (cues, greetings) are user-initiated
        if ev.user_initiated:
            return
        now = self.clock()
        if now < self._drop_until:
            self._drop_until = float("-inf")
            self._interrupt(ev.speech_handle)
            return
        self._auto = (ev.speech_handle, now)

    def on_user_input(self, ev: Any) -> None:
        if not ev.is_final or not is_empty_turn(ev.transcript):
            return
        if self._coach_cut_off:
            # noise cut the coach off: let it finish what it was saying (prompt: no restart)
            return
        now = self.clock()
        if self._auto is not None:
            handle, at = self._auto
            self._auto = None
            if now - at <= AUTO_REPLY_WINDOW_S and not handle.done():
                self._interrupt(handle)
                return
        self._drop_until = now + DROP_WINDOW_S

    def on_item_added(self, ev: Any) -> None:
        item = ev.item
        if getattr(item, "role", None) != "assistant":
            return
        self._coach_cut_off = bool(getattr(item, "interrupted", False))
        text = getattr(item, "text_content", None) or ""
        if not is_placeholder(text):
            return
        now = self.clock()
        logger.warning("coach replied with a placeholder")
        if now - self._retried_at < RETRY_EVERY_S:
            return
        self._retried_at = now
        self.session.generate_reply(user_input=RETRY)

    def _interrupt(self, handle: Any) -> None:
        self.dropped += 1
        logger.info("dropped a reply to an empty turn")
        handle.interrupt(force=True)
