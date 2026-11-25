"""What the athlete asked the coach to keep doing (spec 4.2.2).

"Report my heart rate every minute" was agreed to and then said once (COCH-22): the model has no
clock and no memory of its promises. Requests live here instead; the brain wakes the coach when
a timed one is due, with the request and the current data, and the model words it. Requests that
should outlast the workout ("don't call me 'buddy'") are kept by the agent's athlete memory.
"""

from __future__ import annotations

import itertools
from collections.abc import Iterable
from dataclasses import dataclass

# A request repeated more often than this would crowd out everything else.
MIN_EVERY_S = 30.0
MAX_REQUESTS = 10
MAX_TEXT = 80


@dataclass(slots=True)
class Request:
    id: int
    text: str
    every_s: float | None = None
    """Due every this many seconds of workout; None is a standing instruction."""
    lasting: bool = False
    """Kept for the next workouts too (athlete memory), not only this one."""
    next_at: float | None = None

    def describe(self) -> str:
        every = f"（每 {self.every_s / 60:g} 分钟）" if self.every_s else ""
        lasting = "（长期）" if self.lasting else ""
        return f"#{self.id}「{self.text}」{every}{lasting}"


class Requests:
    def __init__(self) -> None:
        self._items: dict[int, Request] = {}
        self._ids = itertools.count(1)

    def add(self, text: str, *, every_s: float | None, lasting: bool, now: float) -> Request | None:
        text = text.strip()[:MAX_TEXT]
        if not text or len(self._items) >= MAX_REQUESTS:
            return None
        every = max(MIN_EVERY_S, every_s) if every_s else None
        request = Request(next(self._ids), text, every, lasting, now + every if every else None)
        self._items[request.id] = request
        return request

    def restore(self, saved: Iterable[Request], now: float) -> None:
        for r in saved:
            self.add(r.text, every_s=r.every_s, lasting=r.lasting, now=now)

    def remove(self, request_id: int) -> bool:
        return self._items.pop(request_id, None) is not None

    def clear(self) -> int:
        count = len(self._items)
        self._items.clear()
        return count

    def due(self, now: float) -> list[Request]:
        """Timed requests whose time has come; each is scheduled again from now."""
        out = []
        for r in self._items.values():
            if r.every_s and r.next_at is not None and now >= r.next_at:
                r.next_at = now + r.every_s
                out.append(r)
        return out

    @property
    def items(self) -> list[Request]:
        return list(self._items.values())
