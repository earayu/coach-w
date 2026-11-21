"""Wire protocol v1 (docs/spec.md 6.3).

Optional metrics are None when the watch did not measure them, never zero.
"""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, fields
from enum import StrEnum
from typing import Any

PROTOCOL_VERSION = 1
METRICS_TOPIC = "coach.metrics"


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
