"""Contract between the token API and the coach agent (docs/spec.md 3.1).

The API signs `SessionMeta` into the athlete's LiveKit token as participant metadata; the
agent reads it back from the participant. The athlete cannot change it (no
`can_update_own_metadata` grant).
"""

from __future__ import annotations

import json
import uuid
from collections.abc import Mapping
from dataclasses import asdict, dataclass

AGENT_NAME = "coach-w"
# RPC the phone calls every few seconds to tell a dead link from a quiet one (COCH-15).
HEARTBEAT_METHOD = "coach.ping"
# Text models a phone may pick to write the coach's cues (spec 4.2.1). Measured 2026-11-23 on the
# COCH-15 cases (a bike's "kilometre" at 72 steps a minute, a normal 5'30" one): all three
# questioned the bike and praised the run, in about 1 s, 1.6 s and 0.6 s.
DEFAULT_WRITER_MODELS = ("qwen3.8-flash", "qwen3.8-max", "deepseek-v4.1-flash")


def writer_models(env: Mapping[str, str]) -> tuple[str, ...]:
    """Models a phone may pick (`COACHW_WRITER_MODELS`, comma-separated)."""
    raw = env.get("COACHW_WRITER_MODELS")
    if raw is None:
        return DEFAULT_WRITER_MODELS
    return tuple(m.strip() for m in raw.split(",") if m.strip())


# RPC the coach calls on the athlete's phone to look around them (spec 7.5).
PLACES_METHOD = "coach.places"


def parse_athlete_id(raw: str) -> str:
    """Normalize an athlete id (a UUID generated on the phone). Raises ValueError."""
    return str(uuid.UUID(raw))


@dataclass(frozen=True, slots=True)
class SessionMeta:
    athlete_id: str
    max_session_s: int
    cue_writer: str = ""
    """Text model that writes the coach's cues (developer setting, spec 4.2.1); "" = none."""

    def to_json(self) -> str:
        return json.dumps(asdict(self), separators=(",", ":"))

    @classmethod
    def from_json(cls, raw: str) -> SessionMeta:
        data = json.loads(raw)
        return cls(
            athlete_id=parse_athlete_id(data["athlete_id"]),
            max_session_s=int(data["max_session_s"]),
            cue_writer=str(data.get("cue_writer") or ""),
        )
