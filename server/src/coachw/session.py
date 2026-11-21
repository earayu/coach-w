"""Contract between the token API and the coach agent (docs/spec.md 3.1).

The API signs `SessionMeta` into the athlete's LiveKit token as participant metadata; the
agent reads it back from the participant. The athlete cannot change it (no
`can_update_own_metadata` grant).
"""

from __future__ import annotations

import json
import uuid
from dataclasses import asdict, dataclass

AGENT_NAME = "coach-w"


def parse_athlete_id(raw: str) -> str:
    """Normalize an athlete id (a UUID generated on the phone). Raises ValueError."""
    return str(uuid.UUID(raw))


@dataclass(frozen=True, slots=True)
class SessionMeta:
    athlete_id: str
    max_session_s: int

    def to_json(self) -> str:
        return json.dumps(asdict(self), separators=(",", ":"))

    @classmethod
    def from_json(cls, raw: str) -> SessionMeta:
        data = json.loads(raw)
        return cls(
            athlete_id=parse_athlete_id(data["athlete_id"]),
            max_session_s=int(data["max_session_s"]),
        )
