"""What the athlete asked the coach to keep doing (spec 4.2.2).

"Report my heart rate every minute" was agreed to and then said once (COCH-22): the model has no
clock and no memory of its promises. Requests live here instead; the brain wakes the coach when
a timed or distance-based one is due, with the request and the current data, and the model words
it. Requests that should outlast the workout ("don't call me 'buddy'") are kept by the agent's
athlete memory.
"""

from __future__ import annotations

import itertools
import math
import re
from collections.abc import Iterable
from dataclasses import dataclass

# A request repeated more often than this would crowd out everything else.
MIN_EVERY_S = 30.0
MIN_EVERY_M = 100.0
MAX_REQUESTS = 10
MAX_TEXT = 80

_CN_NUMBERS = {"半": 0.5, "一": 1.0, "二": 2.0, "两": 2.0, "三": 3.0, "四": 4.0, "五": 5.0}
_EVERY_KM = re.compile(r"每\s*(?:(半|一|二|两|三|四|五|\d+(?:\.\d+)?)\s*)?(?:公里|千米|km)", re.I)
_EVERY_M = re.compile(r"每\s*(\d+(?:\.\d+)?)\s*(?:米|m)(?!in)", re.I)


def parse_distance_m(text: str) -> float | None:
    """Extract a distance interval in metres from Chinese request text when the model omitted it."""
    if m := _EVERY_KM.search(text):
        raw = m.group(1)
        km = 1.0 if not raw else _CN_NUMBERS.get(raw) or float(raw)
        return max(MIN_EVERY_M, km * 1000.0) if km > 0 else None
    if m := _EVERY_M.search(text):
        meters = float(m.group(1))
        return max(MIN_EVERY_M, meters) if meters > 0 else None
    return None


def _next_mark(distance_m: float | None, every_m: float) -> float:
    if distance_m is None or distance_m <= 0:
        return every_m
    return (math.floor(distance_m / every_m) + 1) * every_m


@dataclass(slots=True)
class Request:
    id: int
    text: str
    every_s: float | None = None
    """Due every this many seconds of workout; None is not time-scheduled."""
    every_m: float | None = None
    """Due every this many metres of workout; None is not distance-scheduled."""
    lasting: bool = False
    """Kept for the next workouts too (athlete memory), not only this one."""
    next_at: float | None = None
    next_m: float | None = None

    def describe(self) -> str:
        every = ""
        if self.every_s:
            every = f"（每 {self.every_s / 60:g} 分钟）"
        elif self.every_m:
            if self.every_m >= 1000:
                every = f"（每 {self.every_m / 1000:g} 公里）"
            else:
                every = f"（每 {self.every_m:g} 米）"
        lasting = "（长期）" if self.lasting else ""
        return f"#{self.id}「{self.text}」{every}{lasting}"


class Requests:
    def __init__(self) -> None:
        self._items: dict[int, Request] = {}
        self._ids = itertools.count(1)

    def add(
        self,
        text: str,
        *,
        every_s: float | None = None,
        every_m: float | None = None,
        lasting: bool = False,
        now: float = 0.0,
        distance_m: float | None = None,
    ) -> Request | None:
        text = text.strip()[:MAX_TEXT]
        if not text or len(self._items) >= MAX_REQUESTS:
            return None
        t_every = max(MIN_EVERY_S, every_s) if every_s and every_s > 0 else None
        d_every = max(MIN_EVERY_M, every_m) if every_m and every_m > 0 else None
        request = Request(
            id=next(self._ids),
            text=text,
            every_s=t_every,
            every_m=d_every,
            lasting=lasting,
            next_at=now + t_every if t_every else None,
            next_m=_next_mark(distance_m, d_every) if d_every else None,
        )
        self._items[request.id] = request
        return request

    def restore(
        self, saved: Iterable[Request], now: float, *, distance_m: float | None = None
    ) -> None:
        for r in saved:
            self.add(
                r.text,
                every_s=r.every_s,
                every_m=r.every_m,
                lasting=r.lasting,
                now=now,
                distance_m=distance_m,
            )

    def sync_distance(self, distance_m: float) -> None:
        """Advance distance marks past an already-covered distance (e.g. after `coach.resume`)."""
        for r in self._items.values():
            if r.every_m and (r.next_m is None or r.next_m <= distance_m):
                r.next_m = _next_mark(distance_m, r.every_m)

    def remove(self, request_id: int) -> bool:
        return self._items.pop(request_id, None) is not None

    def clear(self) -> int:
        count = len(self._items)
        self._items.clear()
        return count

    def due(self, now: float, *, distance_m: float | None = None) -> list[Request]:
        """Timed or distance requests whose mark has come; each is scheduled for its next mark."""
        out = []
        for r in self._items.values():
            fired = False
            if r.every_s and r.next_at is not None and now >= r.next_at:
                r.next_at = now + r.every_s
                fired = True
            if (
                r.every_m
                and distance_m is not None
                and r.next_m is not None
                and distance_m >= r.next_m
            ):
                r.next_m = _next_mark(distance_m, r.every_m)
                fired = True
            if fired:
                out.append(r)
        return out

    @property
    def items(self) -> list[Request]:
        return list(self._items.values())
