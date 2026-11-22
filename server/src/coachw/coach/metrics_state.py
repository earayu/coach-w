"""MetricsState: per-session aggregation of metrics frames (spec 3, 4.4).

Windows and trends use the watch's `elapsed_s` as the time base, so a batch of frames the phone
delivers late (HealthKit buffers while the app is suspended) still lands at the right place.
Staleness uses the receive clock: a frame nobody has heard from for a while is not current.
Only frames with `state == running` feed windows, splits and baselines.
"""

from __future__ import annotations

import time
from collections import deque
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from typing import Any

from coachw.coach.format import format_pace
from coachw.protocol import MetricsFrame, WorkoutState

# A frame older than this is not reported as current.
STALE_AFTER_S = 10.0

# Metrics a window or split can aggregate. Coordinates are never aggregated or kept (spec 11).
SAMPLED_FIELDS = (
    "hr_bpm",
    "speed_mps",
    "cadence_spm",
    "power_w",
    "stride_m",
    "gct_ms",
    "vo_cm",
    "alt_m",
)

# Fields the model may see. Coordinates stay out: the model never needs them (spec 11).
TOOL_FIELDS = (
    "activity",
    "state",
    "elapsed_s",
    "hr_bpm",
    "distance_m",
    "speed_mps",
    "cadence_spm",
    "power_w",
    "stride_m",
    "gct_ms",
    "vo_cm",
    "energy_kcal",
    "alt_m",
)

# Totals that do not change while the workout is paused.
STABLE_FIELDS = ("activity", "state", "elapsed_s", "distance_m", "energy_kcal")

# A session that first sees the workout later than this (voice joined or reconnected mid-workout)
# did not witness the start: the split in progress is not timed and the start is not announced.
JOINED_AT_START_S = 60.0

# A window needs this many samples and must cover this share of its length to count.
MIN_WINDOW_SAMPLES = 3
MIN_WINDOW_COVERAGE = 0.6


@dataclass(frozen=True, slots=True)
class Sample:
    elapsed_s: float
    values: dict[str, float]


@dataclass(frozen=True, slots=True)
class WindowStats:
    mean: float
    min: float
    max: float
    count: int
    span_s: float


@dataclass(frozen=True, slots=True)
class Split:
    """One completed split (e.g. a kilometre). `means` holds the averages of sampled fields."""

    index: int
    distance_m: float
    elapsed_s: float
    duration_s: float
    means: dict[str, float]


@dataclass(slots=True)
class _Mean:
    total: float = 0.0
    count: int = 0

    def add(self, value: float) -> None:
        self.total += value
        self.count += 1

    @property
    def value(self) -> float | None:
        return self.total / self.count if self.count else None


@dataclass(slots=True)
class _Means:
    by_field: dict[str, _Mean] = field(default_factory=dict)

    def add(self, values: dict[str, float]) -> None:
        for k, v in values.items():
            self.by_field.setdefault(k, _Mean()).add(v)

    def get(self, name: str, min_count: int = 1) -> float | None:
        m = self.by_field.get(name)
        return m.value if m and m.count >= min_count else None

    def as_dict(self) -> dict[str, float]:
        return {k: m.value for k, m in self.by_field.items() if m.value is not None}


class MetricsState:
    def __init__(
        self,
        *,
        split_m: float | None = 1000.0,
        baseline_s: tuple[float, float] = (300.0, 900.0),
        history_s: float = 300.0,
        stale_after_s: float = STALE_AFTER_S,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.split_m = split_m
        self.baseline_s = baseline_s
        self.history_s = history_s
        self.stale_after_s = stale_after_s
        self._clock = clock
        self._latest: MetricsFrame | None = None
        self._received_at: float | None = None
        self._samples: deque[Sample] = deque()
        self._splits: list[Split] = []
        # (elapsed_s, distance_m) where the current split began; None until a boundary is witnessed
        self._split_start: tuple[float, float] | None = (0.0, 0.0)
        self._next_split = 1
        self._split_means = _Means()
        self._baseline = _Means()
        self._session = _Means()
        self._last_distance: tuple[float, float] | None = None  # (elapsed_s, distance_m)
        self.started = False
        self.first_elapsed_s: float | None = None

    # -- input ---------------------------------------------------------------------------------

    def update(self, frame: MetricsFrame) -> bool:
        """Take `frame` if it is newer than the current one. Late frames never win."""
        if self._latest and (frame.ts, frame.seq) <= (self._latest.ts, self._latest.seq):
            return False
        self._latest = frame
        self._received_at = self._clock()
        if frame.state is WorkoutState.RUNNING:
            self._sample(frame)
        return True

    def _sample(self, frame: MetricsFrame) -> None:
        if self._samples and frame.elapsed_s <= self._samples[-1].elapsed_s:
            return
        if not self.started:
            self.started = True
            self.first_elapsed_s = frame.elapsed_s
        values = {k: float(v) for k in SAMPLED_FIELDS if (v := getattr(frame, k)) is not None}
        sample = Sample(frame.elapsed_s, values)
        self._samples.append(sample)
        while self._samples and self._samples[0].elapsed_s < frame.elapsed_s - self.history_s:
            self._samples.popleft()
        self._session.add(values)
        if self.baseline_s[0] <= frame.elapsed_s < self.baseline_s[1]:
            self._baseline.add(values)
        if frame.distance_m is not None:
            self._track_splits(frame.elapsed_s, float(frame.distance_m), values)

    def _track_splits(self, elapsed: float, distance: float, values: dict[str, float]) -> None:
        self._split_means.add(values)
        prev = self._last_distance
        self._last_distance = (elapsed, distance)
        if not self.split_m:
            return
        if prev is None:
            if not self.joined_at_start:
                # joined mid-workout: earlier splits were not seen, the current one is partial
                self._split_start = None
                self._next_split = int(distance // self.split_m) + 1
            return
        while distance >= self._next_split * self.split_m:
            boundary = self._next_split * self.split_m
            self._next_split += 1
            # interpolate when the boundary was crossed between the two frames
            p_elapsed, p_distance = prev
            if distance > p_distance and p_distance < boundary:
                frac = (boundary - p_distance) / (distance - p_distance)
                cross = p_elapsed + frac * (elapsed - p_elapsed)
            else:
                cross = elapsed
            if self._split_start is not None:
                self._splits.append(
                    Split(
                        index=int(boundary // self.split_m),
                        distance_m=boundary,
                        elapsed_s=cross,
                        duration_s=cross - self._split_start[0],
                        means=self._split_means.as_dict(),
                    )
                )
            self._split_start = (cross, boundary)
            self._split_means = _Means()

    def seed(
        self,
        *,
        elapsed_s: float,
        distance_m: float | None,
        km_marks_s: Sequence[float],
        means: Mapping[str, float],
        samples: int,
    ) -> None:
        """Continue a workout a previous session saw (`coach.resume`, spec 7.4).

        Rebuilds the completed splits from the kilometre marks, so numbering carries on and the
        split in progress is timed, and seeds the whole-workout means. Per-split averages and the
        baseline of the old session are not recovered. Ignored once this session has its own
        splits: those are first-hand.
        """
        if self._splits:
            return
        self.started = True
        self.first_elapsed_s = min(self.first_elapsed_s or 0.0, 0.0)
        if self.split_m and self.split_m % 1000 == 0:
            per = int(self.split_m // 1000)
            start = 0.0
            for i, mark in enumerate(km_marks_s[per - 1 :: per], start=1):
                self._splits.append(Split(i, i * self.split_m, mark, mark - start, {}))
                start = mark
            self._next_split = len(self._splits) + 1
            self._split_start = (start, len(self._splits) * self.split_m)
            self._split_means = _Means()
        if distance_m is not None and self._last_distance is None:
            self._last_distance = (elapsed_s, distance_m)
        count = max(1, samples)
        for name in SAMPLED_FIELDS:
            if (value := means.get(name)) is not None and name not in self._session.by_field:
                self._session.by_field[name] = _Mean(value * count, count)

    # -- current state -------------------------------------------------------------------------

    @property
    def joined_at_start(self) -> bool:
        """Whether this session saw the workout from (about) its start."""
        return self.first_elapsed_s is not None and self.first_elapsed_s <= JOINED_AT_START_S

    @property
    def latest(self) -> MetricsFrame | None:
        return self._latest

    def age_s(self) -> float | None:
        return None if self._received_at is None else self._clock() - self._received_at

    def is_stale(self) -> bool:
        age = self.age_s()
        return age is None or age > self.stale_after_s

    @property
    def is_running(self) -> bool:
        return self._latest is not None and self._latest.state is WorkoutState.RUNNING

    @property
    def elapsed_s(self) -> float:
        return self._latest.elapsed_s if self._latest else 0.0

    @property
    def distance_m(self) -> float | None:
        return self._last_distance[1] if self._last_distance else None

    @property
    def splits(self) -> list[Split]:
        return list(self._splits)

    # -- windows and trends --------------------------------------------------------------------

    def latest_value(self, name: str) -> float | None:
        return self._samples[-1].values.get(name) if self._samples else None

    def window(self, name: str, seconds: float) -> WindowStats | None:
        """Stats of `name` over the last `seconds` of running time, or None without enough data.

        A missing sensor yields None, so rules built on windows cannot fire on it.
        """
        if not self._samples:
            return None
        since = self._samples[-1].elapsed_s - seconds
        # newest first, stopping at the window's start: rules ask for short windows every second
        values: list[float] = []
        first = last = None
        for s in reversed(self._samples):
            if s.elapsed_s <= since:
                break
            if (v := s.values.get(name)) is not None:
                values.append(v)
                first = s.elapsed_s
                if last is None:
                    last = s.elapsed_s
        if len(values) < MIN_WINDOW_SAMPLES or first is None or last is None:
            return None
        span = last - first
        if span < seconds * MIN_WINDOW_COVERAGE:
            return None
        return WindowStats(
            mean=sum(values) / len(values),
            min=min(values),
            max=max(values),
            count=len(values),
            span_s=span,
        )

    def streak_s(self, name: str, predicate: Callable[[float], bool]) -> float:
        """How long the newest samples have satisfied `predicate` without a break.

        A sample without the metric breaks the streak: no data is never evidence.
        """
        if not self._samples:
            return 0.0
        newest = self._samples[-1].elapsed_s
        start = None
        for s in reversed(self._samples):
            v = s.values.get(name)
            if v is None or not predicate(v):
                break
            start = s.elapsed_s
        return 0.0 if start is None else newest - start

    def baseline(self, name: str) -> float | None:
        """Mean of `name` over the baseline period, once that period is over."""
        if not self._samples or self._samples[-1].elapsed_s < self.baseline_s[1]:
            return None
        return self._baseline.get(name, MIN_WINDOW_SAMPLES)

    def session_mean(self, name: str) -> float | None:
        return self._session.get(name)

    # -- tool results --------------------------------------------------------------------------

    def snapshot(self) -> dict[str, Any]:
        """`get_metrics` result. Missing metrics are omitted, never reported as zero."""
        if self._latest is None:
            return {"available": False, "reason": "no metrics received from the watch yet"}
        age_s = round(self.age_s() or 0.0, 1)
        if age_s > self.stale_after_s and not self.is_running:
            # a paused (or ended) watch sends no heartbeat: its totals still hold, live readings
            # such as heart rate are old and left out
            data = self._latest.to_dict()
            out = {"available": True, "age_s": age_s, "live_readings": False}
            out |= {k: data[k] for k in STABLE_FIELDS if k in data}
            out["state"] = str(out["state"])
            return out
        if age_s > self.stale_after_s:
            return {
                "available": False,
                "reason": f"no new metrics for {age_s:.0f} seconds",
                "age_s": age_s,
            }
        data = self._latest.to_dict()
        out: dict[str, Any] = {"available": True, "age_s": age_s}
        out |= {k: data[k] for k in TOOL_FIELDS if k in data}
        out["state"] = str(out["state"])
        if (speed := data.get("speed_mps")) is not None and (pace := format_pace(speed)):
            out["pace_per_km"] = pace
        return out
