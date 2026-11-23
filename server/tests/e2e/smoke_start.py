"""End-to-end smoke test of the coach before a workout (spec 7.6). Needs a real key.

Joins as the athlete without sending any metrics, so the coach sees no workout yet; answers the
`coach.start` RPC like the phone does; asks with macOS `say` to start a run; and once the coach
has asked the "phone" to start, streams synthetic frames from 0 s like a watch that just started.
Checks that the greeting is the pre-workout one (no numbers), that `start_workout` reached the
phone with `running`, and that the coach announces the start.

Usage (from server/):
  uv run python tests/e2e/smoke_start.py --invite <code> [--api http://127.0.0.1:8000]
Writes ../artifacts/smoke_start.json. Exit code 0 when every check passes.
Not collected by pytest. All metrics here are synthetic.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import sys
import time
import urllib.request
import uuid
from pathlib import Path

from livekit import rtc

sys.path.insert(0, str(Path(__file__).resolve().parent))
from smoke_voice import ARTIFACTS, RATE, SILENCE, peak, say, speak  # noqa: E402

from coachw.protocol import METRICS_TOPIC  # noqa: E402
from coachw.session import START_METHOD  # noqa: E402

DIGITS = re.compile(r"[0-9]|[一二三四五六七八九十百]+(分|秒|公里|次|步)")


def frame(seq: int, elapsed: float) -> bytes:
    now = int(time.time() * 1000)
    return json.dumps(
        {
            "v": 1,
            "seq": seq,
            "ts": now,
            "phone_ts": now,
            "activity": "running",
            "state": "running",
            "elapsed_s": elapsed,
            "hr_bpm": 118,
            "distance_m": round(2.9 * elapsed, 1),
            "speed_mps": 2.9,
        }
    ).encode()


async def main(api_url: str, invite: str) -> int:
    athlete = str(uuid.uuid4())
    req = urllib.request.Request(
        f"{api_url}/v1/session",
        data=json.dumps({"invite_code": invite, "athlete_id": athlete}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        session = json.loads(resp.read())

    room = rtc.Room()
    audio: list[tuple[float, int]] = []
    said: list[tuple[float, str]] = []
    starts: list[str] = []
    watch_started = asyncio.Event()

    @room.on("track_subscribed")
    def _on_track(track: rtc.Track, *_):
        if track.kind == rtc.TrackKind.KIND_AUDIO:

            async def read():
                async for ev in rtc.AudioStream(track, sample_rate=RATE, num_channels=1):
                    audio.append((time.monotonic(), peak(ev.frame)))

            asyncio.create_task(read())

    def _on_transcript(reader: rtc.TextStreamReader, identity: str):
        async def read():
            started = time.monotonic()
            text = await reader.read_all()
            if identity != athlete:
                said.append((started, text))

        asyncio.create_task(read())

    room.register_text_stream_handler("lk.transcription", _on_transcript)

    async def _on_start(data: rtc.RpcInvocationData) -> str:
        starts.append(json.loads(data.payload).get("activity", ""))
        watch_started.set()
        return json.dumps({"ok": True, "status": "waking the watch"})

    await room.connect(session["server_url"], session["token"])
    room.local_participant.register_rpc_method(START_METHOD, _on_start)
    source = rtc.AudioSource(RATE, 1)
    track = rtc.LocalAudioTrack.create_audio_track("mic", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )

    async def watch():
        await watch_started.wait()
        await asyncio.sleep(3)  # the watch wakes up
        seq, t0 = 0, time.monotonic()
        while True:
            seq += 1
            await room.local_participant.publish_data(
                frame(seq, round(time.monotonic() - t0, 1)), reliable=True, topic=METRICS_TOPIC
            )
            await asyncio.sleep(1)

    watch_task = asyncio.create_task(watch())

    def speaking_since(t: float) -> bool:
        return any(ts >= t and p > SILENCE for ts, p in audio)

    async def until_quiet(timeout: float, quiet: float = 2.5) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if audio and not speaking_since(time.monotonic() - quiet):
                return
            await asyncio.sleep(0.1)

    def since(t: float) -> str:
        return " ".join(text for ts, text in said if ts >= t)

    checks: dict[str, bool] = {}
    start = time.monotonic()
    while time.monotonic() < start + 45 and not speaking_since(start):
        await asyncio.sleep(0.1)
    await until_quiet(30)
    await asyncio.sleep(2)
    greeting = since(start)
    checks["pre_workout_greeting_has_no_numbers"] = bool(greeting) and not DIGITS.search(greeting)

    t = time.monotonic()
    await speak(source, say("好，我们开始跑步吧。"))
    with_timeout = time.monotonic() + 40
    while time.monotonic() < with_timeout and not starts:
        await asyncio.sleep(0.2)
    checks["start_workout_reached_the_phone"] = starts == ["running"]
    await until_quiet(40)
    await asyncio.sleep(15)  # the first frames arrive and the start milestone goes out
    await until_quiet(40)
    await asyncio.sleep(2)
    after = since(t)
    checks["coach_spoke_after_the_start"] = bool(after)

    watch_task.cancel()
    await room.disconnect()
    result = {
        "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "checks": checks,
        "greeting": greeting,
        "after_start_request": after,
        "start_calls": starts,
    }
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "smoke_start.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000")
    p.add_argument("--invite", required=True)
    args = p.parse_args()
    sys.exit(asyncio.run(main(args.api, args.invite)))
