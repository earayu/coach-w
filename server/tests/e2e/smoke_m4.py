"""M4 end-to-end smoke: a session resumed mid-workout, and a ride read in km/h. Needs a real key.

Runs against a local stack (./scripts/dev.sh) like smoke_voice.py, in two rooms:
1. resume: as the phone does after a reconnect, sends `coach.resume` (21 minutes, 3.85 km,
   three kilometres done) the moment the agent joins, then streams running frames from there.
   Checks that the agent applied it, greets with "back online" instead of a first-time greeting,
   never announces the start, and announces kilometre 4 (not 1) when it is crossed.
2. cycling: streams cycling frames at 7 m/s (25.2 km/h) and asks for the speed. Checks that
   the cycling profile loaded, `get_metrics` was called and the answer is in km/h, not pace.

Usage (from server/):
  uv run python tests/e2e/smoke_m4.py --invite <code> [--api http://127.0.0.1:8000]
Writes ../artifacts/smoke_m4.json. Exit code 0 when every check passes.
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

from coachw.protocol import CUE_TOPIC, METRICS_TOPIC, RESUME_TOPIC

RESUME = {
    "v": 1,
    "activity": "running",
    "state": "running",
    "elapsed_s": 1260.0,
    "distance_m": 3880.0,
    "energy_kcal": 286.0,
    "km_marks_s": [318.4, 640.1, 965.8],
    "means": {"hr_bpm": 151.3, "speed_mps": 3.08},
    "samples": 1180,
}
RUN_MPS = 3.03
RIDE_MPS = 7.0


class Room:
    """One athlete in one room: frames out, cues and transcripts in."""

    def __init__(self, api_url: str, invite: str) -> None:
        self.api_url, self.invite = api_url, invite
        self.athlete = str(uuid.uuid4())
        self.room = rtc.Room()
        self.audio: list[tuple[float, int]] = []
        self.said: list[tuple[float, str]] = []
        self.cues: list[dict] = []
        self.t0 = time.monotonic()

    async def join(self, on_agent=None) -> None:
        req = urllib.request.Request(
            f"{self.api_url}/v1/session",
            data=json.dumps({"invite_code": self.invite, "athlete_id": self.athlete}).encode(),
            headers={"Content-Type": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as resp:
            session = json.loads(resp.read())

        @self.room.on("track_subscribed")
        def _on_track(track: rtc.Track, *_):
            if track.kind == rtc.TrackKind.KIND_AUDIO:

                async def read():
                    async for ev in rtc.AudioStream(track, sample_rate=RATE, num_channels=1):
                        self.audio.append((time.monotonic(), peak(ev.frame)))

                asyncio.create_task(read())

        @self.room.on("data_received")
        def _on_data(packet: rtc.DataPacket):
            if packet.topic == CUE_TOPIC:
                self.cues.append(json.loads(packet.data))

        @self.room.on("participant_connected")
        def _on_participant(p: rtc.RemoteParticipant):
            if on_agent and p.kind == rtc.ParticipantKind.PARTICIPANT_KIND_AGENT:
                asyncio.create_task(on_agent())

        def _on_transcript(reader: rtc.TextStreamReader, identity: str):
            async def read():
                started = time.monotonic()
                text = await reader.read_all()
                if identity != self.athlete:
                    self.said.append((started, text))

            asyncio.create_task(read())

        self.room.register_text_stream_handler("lk.transcription", _on_transcript)
        await self.room.connect(session["server_url"], session["token"])
        self.source = rtc.AudioSource(RATE, 1)
        track = rtc.LocalAudioTrack.create_audio_track("mic", self.source)
        await self.room.local_participant.publish_track(
            track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE)
        )

    async def publish(self, topic: str, payload: dict) -> None:
        await self.room.local_participant.publish_data(
            json.dumps(payload).encode(), reliable=True, topic=topic
        )

    async def stream(self, activity: str, start_s: float, start_m: float, mps: float) -> None:
        seq, t = 0, time.monotonic()
        while True:
            seq += 1
            elapsed = round(start_s + time.monotonic() - t, 1)
            now = int(time.time() * 1000)
            await self.publish(
                METRICS_TOPIC,
                {
                    "v": 1,
                    "seq": seq,
                    "ts": now,
                    "phone_ts": now,
                    "activity": activity,
                    "state": "running",
                    "elapsed_s": elapsed,
                    "hr_bpm": 143,
                    "distance_m": round(start_m + mps * (elapsed - start_s), 1),
                    "speed_mps": mps,
                },
            )
            await asyncio.sleep(1)

    def speaking_since(self, t: float) -> bool:
        return any(ts >= t and p > SILENCE for ts, p in self.audio)

    async def until_quiet(self, timeout: float, quiet: float = 2.5) -> None:
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if self.audio and not self.speaking_since(time.monotonic() - quiet):
                return
            await asyncio.sleep(0.1)

    def transcripts(self) -> list[tuple[float, str]]:
        return [(round(ts - self.t0, 1), text) for ts, text in self.said]


async def resume_run(api_url: str, invite: str) -> tuple[dict, dict]:
    r = Room(api_url, invite)

    async def send_resume():
        await r.publish(RESUME_TOPIC, RESUME | {"ts": int(time.time() * 1000)})

    log_offset = len(agent_log(None))
    await r.join(on_agent=send_resume)
    # an agent that was already in the room when we joined gets it now, as the phone does
    agent = rtc.ParticipantKind.PARTICIPANT_KIND_AGENT
    if any(p.kind == agent for p in r.room.remote_participants.values()):
        await send_resume()
    streaming = asyncio.create_task(
        r.stream("running", RESUME["elapsed_s"], RESUME["distance_m"], RUN_MPS)
    )
    # 3880 m → 4000 m at 3.03 m/s takes ~40 s
    end = time.monotonic() + 90
    while time.monotonic() < end and not any(c.get("kind") == "split:4" for c in r.cues):
        await asyncio.sleep(0.5)
    await asyncio.sleep(2)
    await r.until_quiet(30)
    await asyncio.sleep(2)
    streaming.cancel()
    await r.room.disconnect()
    await asyncio.sleep(1)

    log = agent_log(None)[log_offset:]
    said = r.transcripts()
    greeting = said[0][1] if said else ""
    kinds = [c.get("kind") for c in r.cues]
    checks = {
        "resume_applied": "workout resumed with 3 splits" in log,
        "greeting_is_back_online": bool(re.search(r"连上|回来|在线|继续", greeting)),
        "greeting_numbers_from_resume": set(re.findall(r"\d+", greeting)) <= {"21", "3", "88"},
        "no_start_cue": "start" not in kinds,
        "split_4_announced": "split:4" in kinds,
        "no_old_splits_repeated": not {"split:1", "split:2", "split:3"} & set(kinds),
        "no_loop_errors": "coach loop step failed" not in log,
    }
    return checks, {"room": "resume", "cues": r.cues, "transcripts": said}


async def cycling_run(api_url: str, invite: str) -> tuple[dict, dict]:
    r = Room(api_url, invite)
    log_offset = len(agent_log(None))
    await r.join()
    streaming = asyncio.create_task(r.stream("cycling", 0.0, 0.0, RIDE_MPS))
    await asyncio.sleep(20)
    await r.until_quiet(30)
    offset = len(agent_log(None))
    pcm = say("我现在骑得有多快？")
    t = time.monotonic()
    await speak(r.source, pcm)
    end = time.monotonic() + 30
    while time.monotonic() < end and not r.speaking_since(t + len(pcm) / (RATE * 2)):
        await asyncio.sleep(0.1)
    await r.until_quiet(40)
    await asyncio.sleep(3)
    streaming.cancel()
    await r.room.disconnect()
    await asyncio.sleep(1)

    log = agent_log(None)
    answer = " ".join(text for ts, text in r.said if ts >= t)
    first = r.said[0][1] if r.said else ""
    checks = {
        # a fresh session greets first; the start cue comes after it
        "fresh_greeting_first": "教练" in first,
        "cycling_profile_loaded": "profile loaded: cycling" in log[log_offset:],
        "speed_tool_called": "tool get_metrics called" in log[offset:],
        "answer_in_km_per_hour": bool(re.search(r"25|二十五", answer))
        and bool(re.search(r"公里|千米", answer)),
        "answer_not_pace": "配速" not in answer and "每公里" not in answer,
    }
    return checks, {"room": "cycling", "answer": answer, "transcripts": r.transcripts()}


async def main(api_url: str, invite: str) -> int:
    resume_checks, resume_detail = await resume_run(api_url, invite)
    cycling_checks, cycling_detail = await cycling_run(api_url, invite)
    checks = resume_checks | cycling_checks
    result = {
        "date": time.strftime("%Y-%m-%d %H:%M:%S"),
        "checks": checks,
        "resume": resume_detail,
        "cycling": cycling_detail,
    }
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "smoke_m4.json").write_text(json.dumps(result, ensure_ascii=False, indent=2))
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if all(checks.values()) else 1


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--api", default="http://127.0.0.1:8000")
    p.add_argument("--invite", required=True)
    args = p.parse_args()
    sys.exit(asyncio.run(main(args.api, args.invite)))
