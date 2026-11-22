"""M3 end-to-end smoke: proactive cues, coach.cue, and coach tools. Needs a real key.

Runs against a local stack (./scripts/dev.sh) like smoke_voice.py. Streams synthetic running
frames from the start of a workout, raises the heart rate above the safety ceiling, and checks
that the coach speaks without being asked, that `coach.cue` packets arrive for the start and the
heart-rate emergency, and that progress / quiet questions go through `get_progress` / `set_quiet`.

Usage (from server/):
  uv run python tests/e2e/smoke_coach.py --invite <code> [--api http://127.0.0.1:8000]
Writes ../artifacts/smoke_coach.json. Exit code 0 when every check passes.
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

from livekit import rtc
from smoke_voice import ARTIFACTS, RATE, SILENCE, agent_log, peak, say, speak

from coachw.protocol import CUE_TOPIC, METRICS_TOPIC, CoachCue

# Command that prints the agent log (e.g. ssh + docker compose logs); None reads logs/agent.log
LOG_CMD: str | None = None

SPEED_MPS = 1000 / 330
CALM_HR, HIGH_HR = 141, 193  # 193 > 184, the default safety ceiling (spec 5.3)


async def main(api_url: str, invite: str) -> int:
    athlete = str(uuid.uuid4())
    req = urllib.request.Request(
        f"{api_url}/v1/session",
        data=json.dumps({"invite_code": invite, "athlete_id": athlete}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        session = json.loads(resp.read())
    log_offset = len(agent_log(LOG_CMD))

    room = rtc.Room()
    audio: list[tuple[float, int]] = []
    said: list[tuple[float, str]] = []
    cues: list[tuple[float, dict]] = []
    t0 = time.monotonic()
    hr = {"value": CALM_HR}

    @room.on("track_subscribed")
    def _on_track(track: rtc.Track, *_):
        if track.kind == rtc.TrackKind.KIND_AUDIO:

            async def read():
                async for ev in rtc.AudioStream(track, sample_rate=RATE, num_channels=1):
                    audio.append((time.monotonic(), peak(ev.frame)))

            asyncio.create_task(read())

    @room.on("data_received")
    def _on_data(packet: rtc.DataPacket):
        if packet.topic == CUE_TOPIC:
            cue = CoachCue.from_json(packet.data)
            cues.append((round(time.monotonic() - t0, 1), cue.to_dict()))

    def _on_transcript(reader: rtc.TextStreamReader, identity: str):
        async def read():
            started = time.monotonic()
            text = await reader.read_all()
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
        seq, start = 0, time.monotonic()
        while True:
            seq += 1
            elapsed = round(time.monotonic() - start, 1)
            now = int(time.time() * 1000)
            frame = {
                "v": 1,
                "seq": seq,
                "ts": now,
                "phone_ts": now,
                "activity": "running",
                "state": "running",
                "elapsed_s": elapsed,
                "hr_bpm": hr["value"],
                "distance_m": round(SPEED_MPS * elapsed, 1),
                "speed_mps": round(SPEED_MPS, 3),
                "cadence_spm": 172,
            }
            await room.local_participant.publish_data(
                json.dumps(frame).encode(), reliable=True, topic=METRICS_TOPIC
            )
            await asyncio.sleep(1)

    metrics_task = asyncio.create_task(stream_metrics())

    def speaking_since(t: float) -> bool:
        return any(ts >= t and p > SILENCE for ts, p in audio)

    async def until_quiet(timeout: float, quiet: float = 2.5) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if audio and not speaking_since(time.monotonic() - quiet):
                return
            await asyncio.sleep(0.1)

    def speech_spans() -> list[tuple[float, float]]:
        spans: list[list[float]] = []
        for ts, p in audio:
            if p <= SILENCE:
                continue
            t = round(ts - t0, 1)
            if spans and t - spans[-1][1] < 1.0:
                spans[-1][1] = t
            else:
                spans.append([t, t])
        return [(a, b) for a, b in spans]

    def text_since(t: float) -> str:
        return " ".join(text for ts, text in said if ts >= t)

    async def ask(question: str) -> dict:
        offset = len(agent_log(LOG_CMD))
        pcm = say(question)
        t = time.monotonic()
        await speak(source, pcm)
        end = time.monotonic() + 30
        while time.monotonic() < end and not speaking_since(t + len(pcm) / (RATE * 2)):
            await asyncio.sleep(0.1)
        await until_quiet(40)
        await asyncio.sleep(2)
        tools = re.findall(r"tool (\w+) called", agent_log(LOG_CMD)[offset:])
        return {"question": question, "answer": text_since(t), "tools": tools}

    checks: dict[str, bool] = {}
    # greeting, then the start milestone spoken unprompted
    await asyncio.sleep(25)
    await until_quiet(30)
    checks["start_cue_received"] = any(c["kind"] == "start" for _, c in cues)

    # heart rate above the safety ceiling: emergency cue within ~15 s of streak + 1 s tick
    t_high = time.monotonic()
    hr["value"] = HIGH_HR
    end = t_high + 40
    while time.monotonic() < end and not any(c["kind"] == "hr_emergency" for _, c in cues):
        await asyncio.sleep(0.2)
    emergency = next((c for _, c in cues if c["kind"] == "hr_emergency"), None)
    checks["emergency_cue_received"] = emergency is not None
    checks["emergency_cue_has_expiry"] = bool(
        emergency and emergency["expires_at"] > emergency["ts"] and emergency.get("haptic")
    )
    await asyncio.sleep(1)
    await until_quiet(30)
    hr["value"] = CALM_HR

    # let one status summary go in (every 45 s while idle) and check nothing replied to it
    t_idle = time.monotonic()
    await asyncio.sleep(50)

    progress = await ask("我已经跑了多长时间了？")
    checks["progress_tool_called"] = "get_progress" in progress["tools"]
    quiet = await ask("请安静五分钟。")
    checks["set_quiet_called"] = "set_quiet" in quiet["tools"]

    # an emergency while the coach is talking cuts in (session.interrupt + reply)
    hr["value"] = CALM_HR
    await speak(source, say("现在可以说话了。给我讲一个长一点的关于马拉松的故事，至少讲一分钟。"))
    end = time.monotonic() + 30
    while time.monotonic() < end and not speaking_since(time.monotonic() - 0.5):
        await asyncio.sleep(0.1)
    t_story = time.monotonic()
    hr["value"] = HIGH_HR
    seen = len(cues)
    end = time.monotonic() + 60
    while time.monotonic() < end and not any(c["kind"] == "hr_emergency" for _, c in cues[seen:]):
        await asyncio.sleep(0.2)
    cut_in = next((ts for ts, c in cues[seen:] if c["kind"] == "hr_emergency"), None)
    coach_was_talking = cut_in is not None and speaking_since(t0 + cut_in - 1.0)
    hr["value"] = CALM_HR
    await asyncio.sleep(3)
    await until_quiet(40)
    await asyncio.sleep(3)

    metrics_task.cancel()
    await room.disconnect()
    await asyncio.sleep(1)

    # transcripts arrive when their stream closes, so read them only now
    def text_between(a: float, b: float) -> str:
        return " ".join(text for ts, text in said if a <= ts < b)

    emergency_speech = text_between(t_high, t_idle)
    idle_speech = text_between(t_idle, t_idle + 50)
    # the model may or may not read the number out; any digits it says must come from the cue
    checks["emergency_spoken"] = "心率" in emergency_speech
    checks["emergency_numbers_from_cue"] = set(re.findall(r"\d+", emergency_speech)) <= {
        str(HIGH_HR),
        "184",
        "15",
    }
    checks["no_reply_to_status_summary"] = idle_speech == ""
    checks["emergency_while_talking_released"] = cut_in is not None
    after_cut = [
        (round(ts - t0, 1), text) for ts, text in said if cut_in is not None and ts >= t0 + cut_in
    ]
    checks["emergency_cut_in_spoken"] = any("心率" in text for _, text in after_cut)

    log = agent_log(LOG_CMD)[log_offset:]
    checks["profile_loaded"] = "profile loaded: running" in log
    checks["no_loop_errors"] = "coach loop step failed" not in log
    result = {
        "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "room": session["room"],
        "checks": checks,
        "cues": cues,
        "emergency_speech": emergency_speech,
        "speech_while_idle_with_status_summary": idle_speech,
        "turns": [progress, quiet],
        "story_started_s": round(t_story - t0, 1),
        "cut_in_cue_s": cut_in,
        "coach_was_talking_at_cut_in": coach_was_talking,
        "speech_after_cut_in": after_cut,
        "agent_transcripts": [(round(ts - t0, 1), text) for ts, text in said],
        "agent_audio_s": speech_spans(),
        "released": re.findall(
            r"cue released id=\S+ kind=(\S+) priority=(\S+) interrupt=(\S+)", log
        ),
    }
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "smoke_coach.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000")
    p.add_argument("--invite", required=True)
    p.add_argument("--agent-log-cmd", help="prints the agent log, e.g. ssh + docker compose logs")
    args = p.parse_args()
    LOG_CMD = args.agent_log_cmd
    sys.exit(asyncio.run(main(args.api, args.invite)))
