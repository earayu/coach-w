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
import re
from collections.abc import Callable, Iterable
from datetime import UTC, datetime, timedelta
from pathlib import Path

from coachw.coach.requests import Request

logger = logging.getLogger("coachw.agent")

# A request for one workout outlives a reconnect, not the day.
WORKOUT_REQUEST_KEEP = timedelta(hours=3)
# Deduplicate feedback when both deterministic detection and the model's `note_feedback` save it.
FEEDBACK_DEDUP_WINDOW = timedelta(seconds=60)
_PUNCT = re.compile(r"[\s\W_]+")


def _norm(text: str) -> str:
    return _PUNCT.sub("", text).lower()


def _similar_feedback(a: str, b: str) -> bool:
    na, nb = _norm(a), _norm(b)
    if not na or not nb:
        return na == nb
    if na == nb:
        return True
    shorter, longer = (na, nb) if len(na) <= len(nb) else (nb, na)
    if len(shorter) >= 4 and shorter in longer:
        return True
    if len(shorter) < 4:
        return False
    common = sum(1 for ch in set(shorter) if ch in set(longer))
    return common / len(set(shorter)) >= 0.55


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
        self._saved_at: dict[tuple[str, float | None, float | None, bool], str] = {}
        self._recent_feedback: list[tuple[datetime, str]] = []

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
                    every_m=float(raw["every_m"]) if raw.get("every_m") else None,
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
            record = {
                "text": r.text,
                "every_s": r.every_s,
                "lasting": r.lasting,
                "saved_at": saved_at,
            }
            if r.every_m:
                record["every_m"] = r.every_m
            records.append(record)
        self._write(self.path, json.dumps({"requests": records}, ensure_ascii=False), "w")

    def note_feedback(self, text: str) -> bool:
        cleaned = text.strip()
        if not cleaned:
            return False
        now = self._clock()
        self._recent_feedback = [
            (ts, old) for ts, old in self._recent_feedback if now - ts <= FEEDBACK_DEDUP_WINDOW
        ]
        if any(_similar_feedback(cleaned, old) for _, old in self._recent_feedback):
            return True
        path = self.directory / "feedback" / f"{now:%Y-%m-%d}.jsonl"
        record = {"ts": now.isoformat(), "athlete_id": self.athlete_id, "text": cleaned}
        ok = self._write(path, json.dumps(record, ensure_ascii=False) + "\n", "a")
        if ok:
            self._recent_feedback.append((now, cleaned))
        return ok

    @staticmethod
    def _key(r: Request) -> tuple[str, float | None, float | None, bool]:
        return (r.text, r.every_s, r.every_m, r.lasting)

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
