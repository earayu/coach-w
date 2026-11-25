"""What the coach keeps about an athlete between sessions, on the server (spec 11).

- Requests (spec 4.2.2): a reconnect starts a new coach, which used to forget "report my heart
  rate every minute" (COCH-22). Workout requests are kept for a few hours; lasting ones ("call
  me by my name") until the athlete takes them back.
- Product feedback the athlete gives by voice, one line per note, for the developers. The coach
  used to say "noted" with nowhere to note it.

Both live next to the transcripts (`COACHW_TRANSCRIPT_DIR`): `memory/<athlete_id>.json` and
`feedback/<YYYY-MM-DD>.jsonl`. They hold the athlete's words, never metric values. Write errors
are logged, never raised.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Callable, Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from coachw.coach.requests import Request

logger = logging.getLogger("coachw.agent")

# A request for one workout outlives a reconnect, not the day.
WORKOUT_REQUEST_KEEP = timedelta(hours=3)


class AthleteMemory:
    def __init__(
        self,
        directory: Path,
        athlete_id: str,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self.directory = directory
        self.athlete_id = athlete_id
        self._clock = clock
        self.path = directory / "memory" / f"{athlete_id}.json"
        self._saved_at: dict[tuple[str, float | None, bool], str] = {}

    def load(self) -> list[Request]:
        try:
            data = json.loads(self.path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            return []
        except (OSError, ValueError) as e:
            logger.warning("athlete memory unreadable: %s", type(e).__name__)
            return []
        now = self._clock()
        out = []
        for raw in data.get("requests", []) if isinstance(data, dict) else []:
            try:
                saved_at = datetime.fromisoformat(raw["saved_at"])
                request = Request(
                    id=0,
                    text=str(raw["text"]),
                    every_s=float(raw["every_s"]) if raw.get("every_s") else None,
                    lasting=bool(raw.get("lasting")),
                )
            except (KeyError, TypeError, ValueError):
                continue
            if not request.lasting and now - saved_at > WORKOUT_REQUEST_KEEP:
                continue
            self._saved_at[self._key(request)] = raw["saved_at"]
            out.append(request)
        return out

    def save(self, requests: Iterable[Request]) -> None:
        now = self._clock().isoformat()
        records = []
        for r in requests:
            saved_at = self._saved_at.setdefault(self._key(r), now)
            records.append(
                {"text": r.text, "every_s": r.every_s, "lasting": r.lasting, "saved_at": saved_at}
            )
        self._write(self.path, json.dumps({"requests": records}, ensure_ascii=False), "w")

    def note_feedback(self, text: str) -> bool:
        now = self._clock()
        path = self.directory / "feedback" / f"{now:%Y-%m-%d}.jsonl"
        record = {"ts": now.isoformat(), "athlete_id": self.athlete_id, "text": text.strip()}
        return self._write(path, json.dumps(record, ensure_ascii=False) + "\n", "a")

    @staticmethod
    def _key(r: Request) -> tuple[str, float | None, bool]:
        return (r.text, r.every_s, r.lasting)

    @staticmethod
    def _write(path: Path, text: str, mode: str) -> bool:
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open(mode, encoding="utf-8") as f:
                f.write(text)
            return True
        except OSError as e:
            logger.warning("athlete memory write failed: %s", type(e).__name__)
            return False
