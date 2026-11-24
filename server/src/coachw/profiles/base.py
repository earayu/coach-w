"""Declarative activity profile (spec 5.1).

A profile says what one kind of activity cares about; the kernel in `coachw.coach` runs it.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import TYPE_CHECKING, Any

from coachw.coach.events import Rule
from coachw.coach.metrics_state import Split

if TYPE_CHECKING:
    from coachw.coach.brain import CoachBrain


class Mode(StrEnum):
    """Spec 4.6."""

    COACH = "coach"
    COMPANION = "companion"
    GUIDE = "guide"


@dataclass(frozen=True, slots=True)
class Athlete:
    """Athlete inputs a session may know. The phone does not send these yet (spec 3.1)."""

    athlete_id: str
    max_hr_bpm: float | None = None


@dataclass(frozen=True, slots=True)
class MetricSpec:
    """A metric the profile cares about and how to say it, e.g. pace → "每公里 5 分 30 秒"."""

    field: str
    label: str
    read: Callable[[float], str | None]


@dataclass(frozen=True, slots=True)
class Phase:
    """A stage of the workout. It starts after `after_s` of running time, or once `goal_fraction`
    of the goal distance is done (only when a goal is set). Phases are listed in order."""

    name: str
    label: str
    after_s: float | None = None
    goal_fraction: float | None = None


@dataclass(frozen=True, slots=True)
class Cadence:
    """How often the coach talks (spec 4.5 density)."""

    companion_s: float
    """Companion chat after this long without any cue."""
    stable_multiplier: float
    """Companion interval is stretched by this while nothing needed correcting."""
    stable_after_s: float
    """No correction or emergency for this long counts as stable."""
    max_per_minute: int
    """Non-emergency cues released per rolling minute."""
    min_gap_s: float
    """Minimum gap between two non-emergency cues."""


@dataclass(frozen=True, slots=True)
class ProfileTool:
    """An extra tool the model gets for this activity. `handler(brain, args)` returns JSON data."""

    name: str
    description: str
    parameters: dict[str, Any]
    handler: Callable[[CoachBrain, Mapping[str, Any]], dict[str, Any]]


@dataclass(frozen=True, slots=True)
class ActivityProfile:
    name: str
    label: str
    activity_types: tuple[str, ...]
    mode: Mode
    metrics: tuple[MetricSpec, ...]
    phases: tuple[Phase, ...]
    split_m: float | None
    split_label: str
    split_facts: Callable[[Split], str]
    rules: tuple[Rule, ...]
    cadence: Cadence
    prompt: str
    companion_topics: tuple[str, ...]
    default_targets: Callable[[Athlete], dict[str, float]]
    describe_targets: Callable[[Mapping[str, float]], list[str]] = lambda _t: []
    tools: tuple[ProfileTool, ...] = ()
    baseline_s: tuple[float, float] = (300.0, 900.0)
    start_hint: str = "简短地给用户打气，提醒先慢慢热身。"
    """What the coach does with the start milestone."""
    end_hint: str = "用一句话总结，提醒放松拉伸，再问用户这次感觉怎么样。"
    """What the coach does with the end-of-workout summary."""
    spoken_names: tuple[str, ...] = ()
    """Words an athlete uses for this activity, e.g. to start it by voice (spec 7.6)."""
    speed_as_pace: bool = True
    """Speed is read as pace per km (on foot); False reads it as km/h (on wheels)."""
    time_mark_s: float | None = None
    """A milestone every this much running time, for activities without distance splits."""
    time_mark_facts: Callable[[float, float | None], str] = lambda elapsed_s, _kcal: (
        f"已经运动 {elapsed_s / 60:.0f} 分钟。简短地鼓励用户。"
    )
    """Words a time mark from (running time, energy so far in kcal or None)."""
