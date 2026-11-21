"""Wire protocol v1 (docs/spec.md 6.3).

Optional metrics are None when the watch did not measure them, never zero. Fixture files are
named after the message: `metrics_frame_*`, `coach_cue_*` and `coach_resume_*`.
"""

from __future__ import annotations

import itertools
import json
from dataclasses import asdict, dataclass, field, fields
from enum import StrEnum
from typing import Any

PROTOCOL_VERSION = 1
METRICS_TOPIC = "coach.metrics"
CUE_TOPIC = "coach.cue"
RESUME_TOPIC = "coach.resume"


class ProtocolError(ValueError):
    pass


class WorkoutState(StrEnum):
    RUNNING = "running"
    PAUSED = "paused"
    ENDED = "ended"


@dataclass(frozen=True, slots=True)
class MetricsFrame:
    v: int
    seq: int
    ts: int
    activity: str
    state: WorkoutState
    elapsed_s: float
    phone_ts: int | None = None
    hr_bpm: float | None = None
    distance_m: float | None = None
    speed_mps: float | None = None
    cadence_spm: float | None = None
    power_w: float | None = None
    stride_m: float | None = None
    gct_ms: float | None = None
    vo_cm: float | None = None
    energy_kcal: float | None = None
    lat: float | None = None
    lon: float | None = None
    alt_m: float | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> MetricsFrame:
        if not isinstance(data, dict):
            raise ProtocolError("metrics frame must be a JSON object")
        if data.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(f"unsupported protocol version {data.get('v')!r}")
        missing = [k for k in ("seq", "ts", "activity", "state", "elapsed_s") if k not in data]
        if missing:
            raise ProtocolError(f"missing required fields: {missing}")
        known = {f.name for f in fields(cls)}
        values = {k: v for k, v in data.items() if k in known}
        try:
            values["state"] = WorkoutState(values["state"])
        except ValueError as e:
            raise ProtocolError(f"unknown workout state {values['state']!r}") from e
        return cls(**values)

    @classmethod
    def from_json(cls, raw: str | bytes) -> MetricsFrame:
        return cls.from_dict(json.loads(raw))

    def to_dict(self) -> dict[str, Any]:
        return {k: v for k, v in asdict(self).items() if v is not None}


class CuePriority(StrEnum):
    """Highest first (spec 4.5)."""

    EMERGENCY = "emergency"
    CORRECTION = "correction"
    MILESTONE = "milestone"
    COMPANION = "companion"

    @property
    def rank(self) -> int:
        return _PRIORITY_RANK[self]


_PRIORITY_RANK = {p: i for i, p in enumerate(reversed(CuePriority))}


class Haptic(StrEnum):
    """Watch haptic for a cue; mirrors `WKHapticType`."""

    NOTIFICATION = "notification"
    DIRECTION_UP = "direction_up"
    DIRECTION_DOWN = "direction_down"
    SUCCESS = "success"
    FAILURE = "failure"
    RETRY = "retry"
    START = "start"
    STOP = "stop"
    CLICK = "click"


@dataclass(frozen=True, slots=True)
class CoachCue:
    """`coach.cue`: server → iPhone → watch. A cue the watch should buzz and show briefly.

    `ts` and `expires_at` are server Unix milliseconds; receivers drop cues past `expires_at`.
    The text is short display copy, never a metric value the watch could show itself.
    """

    v: int
    id: str
    ts: int
    expires_at: int
    priority: CuePriority
    kind: str | None = None
    haptic: Haptic | None = None
    text: str | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CoachCue:
        if not isinstance(data, dict):
            raise ProtocolError("cue must be a JSON object")
        if data.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(f"unsupported protocol version {data.get('v')!r}")
        missing = [k for k in ("id", "ts", "expires_at", "priority") if k not in data]
        if missing:
            raise ProtocolError(f"missing required fields: {missing}")
        known = {f.name for f in fields(cls)}
        values = {k: v for k, v in data.items() if k in known}
        try:
            values["priority"] = CuePriority(values["priority"])
        except ValueError as e:
            raise ProtocolError(f"unknown cue priority {values['priority']!r}") from e
        if (haptic := values.get("haptic")) is not None:
            # a haptic this build does not know falls back to the generic one
            values["haptic"] = Haptic(haptic) if haptic in Haptic else Haptic.NOTIFICATION
        return cls(**values)

    @classmethod
    def from_json(cls, raw: str | bytes) -> CoachCue:
        return cls.from_dict(json.loads(raw))

    def to_dict(self) -> dict[str, Any]:
        return {
            k: str(v) if isinstance(v, StrEnum) else v
            for k, v in asdict(self).items()
            if v is not None
        }

    def to_json(self) -> bytes:
        return json.dumps(self.to_dict(), ensure_ascii=False, separators=(",", ":")).encode()

    def is_expired(self, now_ms: int) -> bool:
        return now_ms >= self.expires_at


def _number(value: Any, name: str) -> float:
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ProtocolError(f"{name} must be a number")
    return float(value)


@dataclass(frozen=True, slots=True)
class CoachResume:
    """`coach.resume`: iPhone → server, sent when a coach session (re)joins a running workout.

    The iPhone keeps a summary of the workout from the frames it saw, so a new session continues
    where the old one stopped instead of starting over (spec 7.4, 8.1). No coordinates.
    `km_marks_s[i]` is the workout time at which kilometre `i + 1` was completed; `means` are the
    whole-workout averages of sampled metrics over `samples` running frames.
    """

    v: int
    ts: int
    activity: str
    state: WorkoutState
    elapsed_s: float
    distance_m: float | None = None
    energy_kcal: float | None = None
    km_marks_s: tuple[float, ...] = ()
    means: dict[str, float] = field(default_factory=dict)
    samples: int | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> CoachResume:
        if not isinstance(data, dict):
            raise ProtocolError("resume must be a JSON object")
        if data.get("v") != PROTOCOL_VERSION:
            raise ProtocolError(f"unsupported protocol version {data.get('v')!r}")
        missing = [k for k in ("ts", "activity", "state", "elapsed_s") if k not in data]
        if missing:
            raise ProtocolError(f"missing required fields: {missing}")
        try:
            state = WorkoutState(data["state"])
        except ValueError as e:
            raise ProtocolError(f"unknown workout state {data['state']!r}") from e
        marks = data.get("km_marks_s", [])
        means = data.get("means", {})
        if not isinstance(marks, list) or not isinstance(means, dict):
            raise ProtocolError("km_marks_s must be a list and means an object")
        km_marks = tuple(_number(m, "km_marks_s") for m in marks)
        if any(b < a for a, b in itertools.pairwise(km_marks)):
            raise ProtocolError("km_marks_s must not decrease")

        def optional(name: str) -> float | None:
            return None if data.get(name) is None else _number(data[name], name)

        samples = optional("samples")
        return cls(
            v=PROTOCOL_VERSION,
            ts=int(_number(data["ts"], "ts")),
            activity=str(data["activity"]),
            state=state,
            elapsed_s=_number(data["elapsed_s"], "elapsed_s"),
            distance_m=optional("distance_m"),
            energy_kcal=optional("energy_kcal"),
            km_marks_s=km_marks,
            means={str(k): _number(v, "means") for k, v in means.items()},
            samples=None if samples is None else int(samples),
        )

    @classmethod
    def from_json(cls, raw: str | bytes) -> CoachResume:
        return cls.from_dict(json.loads(raw))

    def to_dict(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "v": self.v,
            "ts": self.ts,
            "activity": self.activity,
            "state": str(self.state),
            "elapsed_s": self.elapsed_s,
        }
        optional = {
            "distance_m": self.distance_m,
            "energy_kcal": self.energy_kcal,
            "km_marks_s": list(self.km_marks_s) or None,
            "means": dict(self.means) or None,
            "samples": self.samples,
        }
        return out | {k: v for k, v in optional.items() if v is not None}
