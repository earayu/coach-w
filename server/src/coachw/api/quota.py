"""Daily voice-minute ledger, in memory (docs/spec.md 3.1).

A process restart forgets today's usage. Accepted while there are a handful of users; moves to
the account database when sign-up opens.

Each issued token reserves its session cap until the athlete actually leaves, so parallel tokens
cannot overspend. LiveKit webhooks settle reservations to the real time spent in the room; a token
that is never used stops counting once its join window closes.

Each room reservation follows an explicit five-state lifecycle:

    RESERVED  ──join──▶ ACTIVE ──last leave──▶ SETTLED ──rejoin──▶ REJOINING ──join──▶ ACTIVE
       │                  │                       │                    │
       └──────────────────┴───────────────────────┴────────────────────┴──room_finished──▶ CLOSED
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date, datetime
from enum import StrEnum
from zoneinfo import ZoneInfo


class SessionState(StrEnum):
    RESERVED = "reserved"
    ACTIVE = "active"
    REJOINING = "rejoining"
    SETTLED = "settled"
    CLOSED = "closed"


@dataclass(slots=True)
class _Session:
    key: str
    day: date
    identity: str
    reserved_s: int
    join_deadline: float
    state: SessionState = SessionState.RESERVED
    used_s: float = 0.0
    joined_at: float | None = None
    present: int = 0
    """Connections in the room: a rejoin can arrive before LiveKit lets go of the dropped one."""
    superseded: bool = False
    """The same athlete asked for a newer session: the phone holds one voice session at a time."""

    def counted_s(self, now: float) -> float:
        match self.state:
            case SessionState.RESERVED:
                if self.superseded or now >= self.join_deadline:
                    return 0.0
                return float(self.reserved_s)
            case SessionState.ACTIVE:
                assert self.joined_at is not None
                live_used = self.used_s + max(0.0, now - self.joined_at)
                if self.superseded:
                    # a link that dropped but has not timed out in LiveKit yet: only time spent
                    return live_used
                return max(float(self.reserved_s), live_used)
            case SessionState.REJOINING:
                if self.superseded or now >= self.join_deadline:
                    return self.used_s
                return max(float(self.reserved_s), self.used_s)
            case SessionState.SETTLED | SessionState.CLOSED:
                return self.used_s

    def join(self, at: float) -> None:
        if self.state is SessionState.CLOSED:
            return
        self.present += 1
        if self.state is not SessionState.ACTIVE:
            self.joined_at = at
            self.state = SessionState.ACTIVE

    def leave(self, at: float) -> None:
        if self.state is not SessionState.ACTIVE:
            return
        self.present = max(0, self.present - 1)
        if self.present == 0:
            assert self.joined_at is not None
            self.used_s += max(0.0, at - self.joined_at)
            self.joined_at = None
            self.state = SessionState.SETTLED

    def rejoin(self, now: float, join_window_s: int) -> bool:
        if self.state is SessionState.CLOSED:
            return False
        self.superseded = False
        self.join_deadline = max(self.join_deadline, now + join_window_s)
        if self.state is SessionState.SETTLED:
            self.state = SessionState.REJOINING
        return True

    def supersede(self) -> None:
        if self.state is SessionState.CLOSED:
            return
        self.superseded = True
        if self.state is SessionState.REJOINING:
            self.state = SessionState.SETTLED

    def finish(self, at: float) -> None:
        if self.state is SessionState.CLOSED:
            return
        if self.state is SessionState.ACTIVE and self.joined_at is not None:
            self.used_s += max(0.0, at - self.joined_at)
        self.joined_at = None
        self.present = 0
        self.state = SessionState.CLOSED


class MinuteLedger:
    def __init__(self, tz: ZoneInfo) -> None:
        self._tz = tz
        self._rooms: dict[str, _Session] = {}

    def day(self, now: float) -> date:
        return datetime.fromtimestamp(now, self._tz).date()

    def state_of(self, room: str) -> SessionState | None:
        s = self._rooms.get(room)
        return s.state if s is not None else None

    def used_s(self, key: str, now: float) -> float:
        today = self.day(now)
        self._rooms = {
            room: s
            for room, s in self._rooms.items()
            if s.day == today or s.state is SessionState.ACTIVE
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
                s.supersede()

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

    def reuse(self, room: str, key: str, identity: str, now: float, join_window_s: int) -> bool:
        """The athlete's earlier session, rejoined in the same room (one room per workout,
        COCH-15): it counts as before instead of being superseded. False if unknown or closed."""
        s = self._rooms.get(room)
        if s is None or s.key != key or s.identity != identity or s.day != self.day(now):
            return False
        return s.rejoin(now, join_window_s)

    def joined(self, room: str, identity: str, at: float) -> None:
        s = self._rooms.get(room)
        if s and s.identity == identity:
            s.join(at)

    def left(self, room: str, identity: str, at: float) -> None:
        s = self._rooms.get(room)
        if s and s.identity == identity:
            s.leave(at)

    def room_finished(self, room: str, at: float) -> None:
        """LiveKit finished the room: settle any active participant and prevent future reuse."""
        s = self._rooms.get(room)
        if s is not None:
            s.finish(at)
