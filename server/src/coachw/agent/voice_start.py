"""Starting a workout because the athlete said so (spec 7.6).

The realtime model often agreed out loud ("好嘞，开起来") without calling `start_workout`, or
read the call out as text, and the watch never started (production smoke, 2026-11-24). This
catches a clear "let's start" in the athlete's own words, so the start does not depend on the
model remembering to call the tool. The words for each activity live in the profiles.
"""

from __future__ import annotations

import re

from coachw.profiles.registry import activity_spoken_in

START = re.compile(r"开始|开跑|开骑|出发|走起|开练")
# "not yet", "wait", or a question: not a request to start now
HOLD = re.compile(r"不要|不想|不用|别|还没|没开始|等一下|等等|等会|待会|一会儿|先不|吗|么|没有")


class VoiceStart:
    """Which activity the athlete just asked to start, if any."""

    def __init__(self) -> None:
        self.mentioned: str | None = None

    def heard(self, text: str) -> str | None:
        """Feed each final transcript of the athlete before a workout."""
        named = activity_spoken_in(text)
        if named:
            self.mentioned = named
        if not START.search(text) or HOLD.search(text):
            return None
        return named or self.mentioned
