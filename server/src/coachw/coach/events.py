"""CoachEvent, the generic rule types profiles declare, and the EventEngine (spec 4.4).

Rules look at windows and streaks, never a single sample. Every rule reads its metric through
MetricsState; a missing sensor or target leaves the rule silent, so it cannot raise a false
alarm. Rule types are generic: the activity-specific choice of fields, thresholds and wording is
made by the profile that instantiates them.
"""

from __future__ import annotations

import itertools
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from typing import Protocol

from coachw.coach.metrics_state import MetricsState, Split
from coachw.protocol import CuePriority, Haptic


@dataclass(frozen=True, slots=True)
class CoachEvent:
    """Something worth saying. `facts` carries the numbers the model may use, already worded."""

    kind: str
    priority: CuePriority
    facts: str
    cooldown_key: str
    cooldown_s: float
    ttl_s: float
    haptic: Haptic | None = None
    watch_text: str | None = None


@dataclass(frozen=True, slots=True)
class RuleContext:
    state: MetricsState
    targets: Mapping[str, float]


class Rule(Protocol):
    kind: str
    alert: Alert

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None: ...


# A threshold is a constant or the name of a session target (absent target → rule off).
Threshold = float | str


def resolve(threshold: Threshold, targets: Mapping[str, float]) -> float | None:
    return targets.get(threshold) if isinstance(threshold, str) else threshold


@dataclass(frozen=True, slots=True)
class Alert:
    """How a rule's event is delivered: priority, repeat limits, watch haptic and copy."""

    priority: CuePriority
    cooldown_s: float
    ttl_s: float
    haptic: Haptic | None = None
    watch_text: str | None = None
    key: str | None = None
    """Cooldown key; rules sharing one (e.g. two heart-rate levels) never repeat each other."""
    after_s: float = 0.0
    """The rule stays silent until this much running time (e.g. not during warm-up)."""

    def event(self, kind: str, facts: str, key: str | None = None) -> CoachEvent:
        return CoachEvent(
            kind=kind,
            priority=self.priority,
            facts=facts,
            cooldown_key=key or self.key or kind,
            cooldown_s=self.cooldown_s,
            ttl_s=self.ttl_s,
            haptic=self.haptic,
            watch_text=self.watch_text,
        )


@dataclass(frozen=True, slots=True)
class Sustained:
    """`field` above (or below) a threshold for at least `for_s` seconds without a break.

    `facts(value, threshold, seconds)` words the event.
    """

    kind: str
    field: str
    threshold: Threshold
    for_s: float
    alert: Alert
    facts: Callable[[float, float, float], str]
    above: bool = True

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None:
        limit = resolve(self.threshold, ctx.targets)
        if limit is None:
            return None
        streak = ctx.state.streak_s(
            self.field, (lambda v: v > limit) if self.above else (lambda v: v < limit)
        )
        if streak < self.for_s:
            return None
        value = ctx.state.window(self.field, min(self.for_s, 10.0))
        current = value.mean if value else ctx.state.latest_value(self.field)
        if current is None:
            return None
        return self.alert.event(self.kind, self.facts(current, limit, streak))


@dataclass(frozen=True, slots=True)
class WindowVsBaseline:
    """Mean of `field` over the last `window_s` changed by at least `change` against the
    baseline period (e.g. +0.08 = 8 % higher, -0.05 = 5 % lower).

    `facts(window_mean, baseline, change)` words the event.
    """

    kind: str
    field: str
    window_s: float
    change: float
    alert: Alert
    facts: Callable[[float, float, float], str]

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None:
        base = ctx.state.baseline(self.field)
        window = ctx.state.window(self.field, self.window_s)
        if base is None or window is None or base == 0:
            return None
        change = (window.mean - base) / base
        hit = change >= self.change if self.change > 0 else change <= self.change
        return self.alert.event(self.kind, self.facts(window.mean, base, change)) if hit else None


@dataclass(frozen=True, slots=True)
class WindowVsTarget:
    """Mean of `field` over `window_s`, mapped through `transform`, is off the target by more than
    `tolerance` in the given direction (`+1` above, `-1` below).

    `transform` lets a profile compare in the unit people think in (e.g. speed → seconds per km).
    `facts(window_value, target_value, delta)` words the event, all three already transformed.
    """

    kind: str
    field: str
    window_s: float
    target: str
    tolerance: float
    direction: int
    alert: Alert
    facts: Callable[[float, float, float], str]
    transform: Callable[[float], float | None] = lambda v: v

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None:
        target = ctx.targets.get(self.target)
        window = ctx.state.window(self.field, self.window_s)
        if target is None or window is None:
            return None
        value, goal = self.transform(window.mean), self.transform(target)
        if value is None or goal is None:
            return None
        delta = value - goal
        if delta * self.direction <= self.tolerance:
            return None
        return self.alert.event(self.kind, self.facts(value, goal, delta))


@dataclass(frozen=True, slots=True)
class WindowPair:
    """Over the last `window_s`, the mean of `field` is at least `at_least` while the mean of
    `other` is at most `at_most`: two readings that cannot both be true for the activity (e.g. a
    running pace with a cadence far too low to run it, which is someone on a bike).

    `facts(field_mean, other_mean)` words the event.
    """

    kind: str
    field: str
    at_least: float
    other: str
    at_most: float
    window_s: float
    alert: Alert
    facts: Callable[[float, float], str]

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None:
        first = ctx.state.window(self.field, self.window_s)
        second = ctx.state.window(self.other, self.window_s)
        if first is None or second is None:
            return None
        if first.mean < self.at_least or second.mean > self.at_most:
            return None
        return self.alert.event(self.kind, self.facts(first.mean, second.mean))


@dataclass(frozen=True, slots=True)
class SplitTrend:
    """The last `steps` completed splits each moved by at least `min_step` in one direction
    (`+1` rising, `-1` falling) on `metric(split)`. Fires once per new split.

    `facts(values)` words the event from the `steps + 1` metric values, oldest first.
    """

    kind: str
    metric: Callable[[Split], float | None]
    steps: int
    min_step: float
    direction: int
    alert: Alert
    facts: Callable[[Sequence[float], Sequence[Split]], str]

    def evaluate(self, ctx: RuleContext) -> CoachEvent | None:
        splits = ctx.state.splits[-(self.steps + 1) :]
        if len(splits) < self.steps + 1:
            return None
        values = [self.metric(s) for s in splits]
        if any(v is None for v in values):
            return None
        vals = [v for v in values if v is not None]
        if not all((b - a) * self.direction >= self.min_step for a, b in itertools.pairwise(vals)):
            return None
        key = f"{self.kind}:{splits[-1].index}"
        return self.alert.event(self.kind, self.facts(vals, splits), key=key)


class EventEngine:
    """Evaluates a profile's rules against the current state."""

    def __init__(self, rules: Sequence[Rule]) -> None:
        self.rules = list(rules)

    def evaluate(self, ctx: RuleContext) -> list[CoachEvent]:
        # Old or paused data says nothing about the athlete right now: stay silent.
        if ctx.state.is_stale() or not ctx.state.is_running:
            return []
        elapsed = ctx.state.elapsed_s
        return [
            e
            for rule in self.rules
            if elapsed >= rule.alert.after_s and (e := rule.evaluate(ctx)) is not None
        ]
