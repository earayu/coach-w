"""Daily voice-minute ledger, in memory (docs/spec.md 3.1).

A process restart forgets today's usage. Accepted while there are a handful of users; moves to
the account database when sign-up opens.

Each issued token reserves its session cap until the athlete actually leaves, so parallel tokens
cannot overspend. LiveKit webhooks settle reservations to the real time spent in the room; a token
that is never used stops counting once its join window closes.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from zoneinfo import ZoneInfo


@dataclass(slots=True)
class _Session:
    key: str
    day: date
    identity: str
    reserved_s: int
    join_deadline: float
    used_s: float = 0.0
    joined_at: float | None = None
    ever_joined: bool = False
    superseded: bool = False
    """The same athlete asked for a newer session: the phone holds one voice session at a time."""

    def counted_s(self, now: float) -> float:
        if self.joined_at is not None:
            if self.superseded:
                # a link that dropped but has not timed out in LiveKit yet: only time spent
                return self.used_s + max(0.0, now - self.joined_at)
            return max(self.reserved_s, self.used_s)  # in the room: the agent enforces the cap
        if self.ever_joined:
            return self.used_s
        if self.superseded:
            return 0.0
        return self.reserved_s if now < self.join_deadline else 0.0


class MinuteLedger:
    def __init__(self, tz: ZoneInfo) -> None:
        self._tz = tz
        self._rooms: dict[str, _Session] = {}

    def day(self, now: float) -> date:
        return datetime.fromtimestamp(now, self._tz).date()

    def used_s(self, key: str, now: float) -> float:
        today = self.day(now)
        self._rooms = {
            room: s for room, s in self._rooms.items() if s.day == today or s.joined_at is not None
        }
        return sum(
            s.counted_s(now) for s in self._rooms.values() if s.key == key and s.day == today
        )

    def supersede(self, key: str, identity: str) -> None:
        """The athlete asks for a new session; earlier ones count only the time actually spent.

        A reconnect asks while LiveKit may still count the dropped session as in the room (and a
        failed join leaves an unused token): holding their full reservations made the reconnect
        fail with "minutes used up" whenever the session cap equals the daily minutes.
        """
        for s in self._rooms.values():
            if s.key == key and s.identity == identity:
                s.superseded = True

    def reserve(
        self, key: str, room: str, identity: str, seconds: int, now: float, join_window_s: int
    ) -> None:
        self._rooms[room] = _Session(
            key=key,
            day=self.day(now),
            identity=identity,
            reserved_s=seconds,
            join_deadline=now + join_window_s,
        )

    def joined(self, room: str, identity: str, at: float) -> None:
        s = self._rooms.get(room)
        if s and s.identity == identity and s.joined_at is None:
            s.joined_at = at
            s.ever_joined = True

    def left(self, room: str, identity: str, at: float) -> None:
        s = self._rooms.get(room)
        if s and s.identity == identity and s.joined_at is not None:
            s.used_s += max(0.0, at - s.joined_at)
            s.joined_at = None
