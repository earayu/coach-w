"""End-to-end smoke test against a running local stack (./scripts/dev.sh). Needs a real key.

Gets a token from the token API, joins the room as the athlete, streams synthetic metrics frames
on `coach.metrics`, asks questions with macOS `say`, and checks that the coach's answers use the
numbers from the frames and that the agent called `get_metrics`.

Usage (from server/):
  uv run python tests/e2e/smoke_voice.py --invite <code> [--api http://127.0.0.1:8000]
Against a deployed host, read the agent log over SSH:
  uv run python tests/e2e/smoke_voice.py --invite <code> --api https://coach.example.com \
    --agent-log-cmd "ssh root@<host> docker compose -f /opt/coach-w/deploy/docker-compose.yml \
      logs --no-color --no-log-prefix agent"
Writes ../artifacts/smoke_voice.json. Exit code 0 when every check passes.
Not collected by pytest. All metrics here are synthetic.
"""

from __future__ import annotations

import argparse
import asyncio
import io
import json
import re
import subprocess
import sys
import tempfile
import time
import urllib.request
import uuid
import wave
from pathlib import Path

from livekit import rtc

from coachw.protocol import METRICS_TOPIC

ROOT = Path(__file__).resolve().parents[3]
ARTIFACTS = ROOT / "artifacts"
AGENT_LOG = ROOT / "logs" / "agent.log"
RATE = 16000
FRAME_SAMPLES = RATE // 100  # 10 ms
SILENCE = 300

# distinctive values so a guessed number cannot pass by luck
HR_BPM = 137
SPEED_MPS = 1000 / 332  # 5'32" per km


def say(text: str) -> bytes:
    with tempfile.TemporaryDirectory() as d:
        aiff, wav = Path(d) / "a.aiff", Path(d) / "a.wav"
        voices = subprocess.run(["say", "-v", "?"], capture_output=True, text=True).stdout
        voice = "Tingting" if "Tingting" in voices else "Meijia"
        subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEI16@{RATE}", "-c", "1", str(aiff), str(wav)],
            check=True,
        )
        with wave.open(io.BytesIO(wav.read_bytes())) as w:
            return w.readframes(w.getnframes())


async def speak(source: rtc.AudioSource, pcm: bytes, tail_s: float = 2.0) -> None:
    step = FRAME_SAMPLES * 2
    pcm += b"\x00" * int(tail_s * RATE * 2)
    for i in range(0, len(pcm) - step + 1, step):
        await source.capture_frame(rtc.AudioFrame(pcm[i : i + step], RATE, 1, FRAME_SAMPLES))


def peak(frame: rtc.AudioFrame) -> int:
    data = frame.data
    samples = data if data.format in ("h", "<h") else data.cast("h")
    return max((abs(s) for s in samples), default=0)


def frame_json(seq: int, elapsed: float) -> bytes:
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
            "hr_bpm": HR_BPM,
            "distance_m": round(2400 + SPEED_MPS * elapsed, 1),
            "speed_mps": round(SPEED_MPS, 3),
            "cadence_spm": 171,
        }
    ).encode()


def agent_log(cmd: str | None) -> str:
    """Agent log text: the local dev.sh log, or the output of `cmd` (e.g. ssh + docker logs)."""
    if cmd:
        out = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60)
        return out.stdout
    return AGENT_LOG.read_text(errors="replace") if AGENT_LOG.exists() else ""


async def media_paths(room: rtc.Room) -> list[str]:
    """Nominated ICE pairs as `pc protocol LOCAL->REMOTE:port`, e.g. UDP vs the TCP fallback."""
    stats = await room.get_rtc_stats()
    paths = []
    for pc, items in (("pub", stats.publisher_stats), ("sub", stats.subscriber_stats)):
        cands = {}
        for s in items:
            kind = s.WhichOneof("stats")
            if kind in ("local_candidate", "remote_candidate"):
                c = getattr(s, kind)
                cands[c.rtc.id] = c.candidate
        for s in items:
            if s.WhichOneof("stats") != "candidate_pair":
                continue
            p = s.candidate_pair.candidate_pair
            loc, rem = cands.get(p.local_candidate_id), cands.get(p.remote_candidate_id)
            if p.nominated and loc and rem:
                types = type(loc).DESCRIPTOR.fields_by_name["candidate_type"].enum_type
                lt, rt = (types.values_by_number[c.candidate_type].name for c in (loc, rem))
                paths.append(f"{pc} {loc.protocol} {lt}->{rt}:{rem.port}")
    return paths


def tool_calls(text: str) -> list[str]:
    return re.findall(r"tool get_metrics called available=(\w+)", text)


async def main(api_url: str, invite: str, log_cmd: str | None) -> int:
    athlete = str(uuid.uuid4())
    req = urllib.request.Request(
        f"{api_url}/v1/session",
        data=json.dumps({"invite_code": invite, "athlete_id": athlete}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        session = json.loads(resp.read())

    room = rtc.Room()
    audio: list[tuple[float, int]] = []
    said: list[tuple[float, str]] = []  # (stream start, text) of agent transcripts
    debug: list[dict] = []
    t_start = time.monotonic()

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
            attrs = dict(reader.info.attributes or {})
            debug.append(
                {"t": round(started - t_start, 1), "who": identity, "attrs": attrs, "text": text}
            )
            if identity != athlete:
                said.append((started, text))

        asyncio.create_task(read())

    room.register_text_stream_handler("lk.transcription", _on_transcript)

    await room.connect(session["server_url"], session["token"])
    source = rtc.AudioSource(RATE, 1)
    track = rtc.LocalAudioTrack.create_audio_track("mic", source)
    await room.local_participant.publish_track(
        track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
    )

    async def stream_metrics():
        seq, t0 = 0, time.monotonic()
        while True:
            seq += 1
            await room.local_participant.publish_data(
                frame_json(seq, round(600 + time.monotonic() - t0, 1)),
                reliable=True,
                topic=METRICS_TOPIC,
            )
            await asyncio.sleep(1)

    metrics_task = asyncio.create_task(stream_metrics())

    def speaking_since(t: float) -> bool:
        return any(ts >= t and p > SILENCE for ts, p in audio)

    async def until_quiet(timeout: float, quiet: float = 2.5) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            cutoff = time.monotonic() - quiet
            if audio and not speaking_since(cutoff):
                return
            await asyncio.sleep(0.1)

    async def ask(question: str) -> dict:
        offset = len(agent_log(log_cmd))
        pcm = say(question)
        t = time.monotonic()
        await speak(source, pcm)
        end = time.monotonic() + 30
        while time.monotonic() < end and not speaking_since(t + len(pcm) / (RATE * 2)):
            await asyncio.sleep(0.1)
        await until_quiet(40)
        await asyncio.sleep(2)
        answer = " ".join(text for ts, text in said if ts >= t)
        calls = tool_calls(agent_log(log_cmd)[offset:])
        return {"question": question, "answer": answer, "tool_calls": calls}

    checks: dict[str, bool] = {}
    start = time.monotonic()
    end = start + 45
    while time.monotonic() < end and not speaking_since(start):
        await asyncio.sleep(0.1)
    checks["greeting_audio"] = speaking_since(start)
    await until_quiet(30)

    hr = await ask("我现在心率多少？")
    checks["hr_tool_called"] = "True" in hr["tool_calls"]
    checks["hr_answer_uses_frame"] = bool(re.search(r"137|一百三十七|一三七", hr["answer"]))

    pace = await ask("我现在配速多少？")
    checks["pace_tool_called"] = "True" in pace["tool_calls"]
    checks["pace_answer_uses_frame"] = bool(re.search(r"5\D{0,4}32|五分三十二", pace["answer"]))

    # power is absent from the frames: the coach should say it has no data (recorded, not asserted)
    power = await ask("我现在功率多少瓦？")

    paths = await media_paths(room)
    metrics_task.cancel()
    await room.disconnect()

    result = {
        "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "server_url": session["server_url"],
        "room": session["room"],
        "media_paths": paths,
        "checks": checks,
        "turns": [hr, pace, power],
        "transcripts": debug,
    }
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "smoke_voice.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000")
    p.add_argument("--invite", required=True)
    p.add_argument(
        "--agent-log-cmd",
        help="command printing the agent log of a remote stack (default: logs/agent.log)",
    )
    args = p.parse_args()
    sys.exit(asyncio.run(main(args.api, args.invite, args.agent_log_cmd)))
