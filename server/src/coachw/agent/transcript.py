"""Full conversation transcript of each coach session, kept on the server (spec 11).

The maintainer wants every conversation kept so feedback given by voice is never lost (COCH-13).
Off unless `COACHW_TRANSCRIPT_DIR` is set. One JSON Lines file per session:
`<dir>/<YYYY-MM-DD>/<room>.jsonl`, a header line, then one line per conversation item:
`user` (what the athlete said), `coach` (what the coach said), `cue` (a proactive prompt the coach
system gave the model) and `status` (a background summary). Text is kept as said, which may
include spoken numbers such as heart rate; nothing else from the metrics stream is written.
"""

from __future__ import annotations

import json
import logging
import os
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

logger = logging.getLogger("coachw.agent")

CUE_PREFIX = "【教练提示】"
# the status summary opens with "【运动状态，仅供参考，不要回复】"
STATUS_PREFIX = "【运动状态"


def transcript_dir(env: dict[str, str] | os._Environ[str] = os.environ) -> Path | None:
    value = env.get("COACHW_TRANSCRIPT_DIR", "").strip()
    return Path(value) if value else None


def classify(role: str | None, text: str) -> str | None:
    """Transcript kind of a conversation item; None for items that are not conversation."""
    if role == "assistant":
        return "coach"
    if role == "user":
        if text.startswith(CUE_PREFIX):
            return "cue"
        if text.startswith(STATUS_PREFIX):
            return "status"
        return "user"
    return None


class Transcript:
    """Appends one session's conversation to its file. Write errors are logged, never raised."""

    def __init__(
        self,
        directory: Path,
        *,
        room: str,
        athlete_id: str,
        clock: Callable[[], datetime] = lambda: datetime.now(UTC),
    ) -> None:
        self._clock = clock
        started = clock()
        self.path = directory / started.strftime("%Y-%m-%d") / f"{room}.jsonl"
        self.lines = 0
        self._write(
            {
                "type": "session",
                "ts": started.isoformat(),
                "room": room,
                "athlete_id": athlete_id,
            }
        )

    def add(self, kind: str, text: str, **extra: Any) -> None:
        text = text.strip()
        if not text:
            return
        self._write({"ts": self._clock().isoformat(), "type": kind, "text": text, **extra})

    def on_item_added(self, ev: Any) -> None:
        item = ev.item
        text = getattr(item, "text_content", None) or ""
        kind = classify(getattr(item, "role", None), text)
        if kind is None:
            return
        extra = {"interrupted": True} if getattr(item, "interrupted", False) else {}
        self.add(kind, text, **extra)

    def attach(self, session: Any) -> None:
        session.on("conversation_item_added", self.on_item_added)

    def _write(self, record: dict[str, Any]) -> None:
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as f:
                f.write(json.dumps(record, ensure_ascii=False) + "\n")
            self.lines += 1
        except OSError as e:
            logger.warning("transcript write failed: %s", type(e).__name__)
