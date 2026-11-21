"""Latest metrics frame of one coach session, and what the `get_metrics` tool returns.

M2 keeps only the newest frame in memory. Windows and trends (MetricsState) arrive in M3.
"""

from __future__ import annotations

import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from coachw.protocol import MetricsFrame

# A frame older than this is not reported as current.
STALE_AFTER_S = 10.0

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


def format_pace(speed_mps: float) -> str | None:
    """Pace per kilometre as m'ss\", or None when standing still."""
    if speed_mps < 0.3:
        return None
    total = round(1000 / speed_mps)
    return f"{total // 60}'{total % 60:02d}\""


@dataclass(slots=True)
class _Received:
    frame: MetricsFrame
    at: float


class LatestMetrics:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._latest: _Received | None = None

    @property
    def frame(self) -> MetricsFrame | None:
        return self._latest.frame if self._latest else None

    def update(self, frame: MetricsFrame) -> bool:
        """Keep `frame` if it is newer than the current one. Late frames never win."""
        if self._latest and (frame.ts, frame.seq) <= (
            self._latest.frame.ts,
            self._latest.frame.seq,
        ):
            return False
        self._latest = _Received(frame, self._clock())
        return True

    def snapshot(self) -> dict[str, Any]:
        """Tool result. Missing metrics are omitted, never reported as zero."""
        if self._latest is None:
            return {"available": False, "reason": "no metrics received from the watch yet"}
        age_s = round(self._clock() - self._latest.at, 1)
        if age_s > STALE_AFTER_S:
            return {
                "available": False,
                "reason": f"no new metrics for {age_s:.0f} seconds",
                "age_s": age_s,
            }
        data = self._latest.frame.to_dict()
        out: dict[str, Any] = {"available": True, "age_s": age_s}
        out |= {k: data[k] for k in TOOL_FIELDS if k in data}
        out["state"] = str(out["state"])
        if (speed := data.get("speed_mps")) is not None and (pace := format_pace(speed)):
            out["pace_per_km"] = pace
        return out
