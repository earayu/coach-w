"""CueQueue: decides which pending cue may be spoken now (spec 4.5).

- priority: emergency > correction > milestone > companion
- cooldown: a key released within its cooldown is not offered again
- expiry: a cue past `expires_at` is dropped, never spoken late
- no talking over: nothing but an emergency while the user speaks; while the coach speaks only an
  emergency, which interrupts
- quiet: during `set_quiet` only emergencies pass
- density: at most `max_per_minute` non-emergency cues per rolling minute, `min_gap_s` apart
"""

from __future__ import annotations

import itertools
from collections import deque
from dataclasses import dataclass

from coachw.coach.events import CoachEvent
from coachw.protocol import CuePriority

ALERT_PRIORITIES = (CuePriority.EMERGENCY, CuePriority.CORRECTION)


@dataclass(frozen=True, slots=True)
class Cue:
    id: str
    event: CoachEvent
    created_at: float
    expires_at: float

    @property
    def priority(self) -> CuePriority:
        return self.event.priority


@dataclass(frozen=True, slots=True)
class Release:
    cue: Cue
    interrupt: bool
    """The coach is speaking and this emergency must cut in."""


class CueQueue:
    def __init__(self, *, max_per_minute: int, min_gap_s: float) -> None:
        self.max_per_minute = max_per_minute
        self.min_gap_s = min_gap_s
        self._pending: dict[str, Cue] = {}
        self._released_at: dict[str, tuple[float, int]] = {}  # cooldown key → (time, rank)
        self._recent: deque[float] = deque()  # non-emergency release times
        self._ids = itertools.count(1)
        self.quiet_until = float("-inf")
        self.last_spoken_at: float | None = None
        self.last_alert_at: float | None = None
        self.dropped_expired = 0

    def offer(self, event: CoachEvent, now: float) -> Cue | None:
        """Queue `event` unless its key is cooling down or already pending.

        A more urgent event replaces a pending one with the same key, and is not held back by the
        cooldown of a less urgent one.
        """
        key = event.cooldown_key
        released = self._released_at.get(key)
        if (
            released is not None
            and now - released[0] < event.cooldown_s
            and released[1] >= event.priority.rank
        ):
            return None
        if (pending := self._pending.get(key)) and event.priority.rank <= pending.priority.rank:
            return None
        cue = Cue(
            id=f"cue-{next(self._ids):06d}",
            event=event,
            created_at=now,
            expires_at=now + event.ttl_s,
        )
        self._pending[key] = cue
        return cue

    def next(self, now: float, *, user_speaking: bool, agent_speaking: bool) -> Release | None:
        self._expire(now)
        if not self._pending:
            return None
        candidates = sorted(self._pending.values(), key=lambda c: (-c.priority.rank, c.created_at))
        for cue in candidates:
            if self._allowed(cue, now, user_speaking=user_speaking, agent_speaking=agent_speaking):
                self._release(cue, now)
                emergency = cue.priority is CuePriority.EMERGENCY
                return Release(cue, interrupt=emergency and agent_speaking)
        return None

    def _allowed(self, cue: Cue, now: float, *, user_speaking: bool, agent_speaking: bool) -> bool:
        if cue.priority is CuePriority.EMERGENCY:
            return True
        if user_speaking or agent_speaking or self.is_quiet(now):
            return False
        while self._recent and now - self._recent[0] >= 60:
            self._recent.popleft()
        if len(self._recent) >= self.max_per_minute:
            return False
        return not (self._recent and now - self._recent[-1] < self.min_gap_s)

    def _release(self, cue: Cue, now: float) -> None:
        del self._pending[cue.event.cooldown_key]
        self._released_at[cue.event.cooldown_key] = (now, cue.priority.rank)
        self.last_spoken_at = now
        if cue.priority in ALERT_PRIORITIES:
            self.last_alert_at = now
        if cue.priority is not CuePriority.EMERGENCY:
            self._recent.append(now)

    def _expire(self, now: float) -> None:
        for key, cue in list(self._pending.items()):
            if now >= cue.expires_at:
                del self._pending[key]
                self.dropped_expired += 1

    # -- quiet ---------------------------------------------------------------------------------

    def set_quiet(self, seconds: float, now: float) -> None:
        """Only emergencies pass for `seconds`; 0 ends the quiet period."""
        self.quiet_until = now + seconds if seconds > 0 else float("-inf")
        if seconds > 0:
            # whatever was waiting is no longer wanted
            for key, cue in list(self._pending.items()):
                if cue.priority is not CuePriority.EMERGENCY:
                    del self._pending[key]

    def is_quiet(self, now: float) -> bool:
        return now < self.quiet_until

    def quiet_remaining_s(self, now: float) -> float:
        return max(0.0, self.quiet_until - now)

    @property
    def pending(self) -> list[Cue]:
        return list(self._pending.values())
