import asyncio
import json
import uuid
from pathlib import Path
from types import SimpleNamespace

import pytest

from coachw.agent.coach import INSTRUCTIONS
from coachw.agent.worker import AthleteInbox, end_when_cap_reached, read_session_meta
from coachw.coach.brain import CoachBrain
from coachw.coach.format import format_pace
from coachw.coach.metrics_state import STALE_AFTER_S, MetricsState
from coachw.profiles.base import Athlete
from coachw.protocol import METRICS_TOPIC, MetricsFrame
from coachw.session import SessionMeta

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "fixtures"
FULL = json.loads((FIXTURES / "metrics_frame_v1_full.json").read_text())


class Clock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


def frame(**patch) -> MetricsFrame:
    return MetricsFrame.from_dict(FULL | patch)


def test_no_frame_yet():
    snap = MetricsState().snapshot()
    assert snap["available"] is False


def test_snapshot_reports_frame_without_coordinates():
    clock = Clock()
    store = MetricsState(clock=clock)
    store.update(frame())
    clock.now += 1.5
    snap = store.snapshot()
    assert snap["available"] is True
    assert snap["hr_bpm"] == 152
    assert snap["distance_m"] == 2034.1
    assert snap["age_s"] == 1.5
    assert snap["pace_per_km"] == "5'12\""
    assert "lat" not in snap and "lon" not in snap


def test_missing_metrics_are_omitted_not_zero():
    store = MetricsState()
    store.update(MetricsFrame.from_json((FIXTURES / "metrics_frame_v1_minimal.json").read_text()))
    snap = store.snapshot()
    assert "hr_bpm" not in snap and "pace_per_km" not in snap


def test_stale_frame_is_not_current():
    clock = Clock()
    store = MetricsState(clock=clock)
    store.update(frame())
    clock.now += STALE_AFTER_S + 1
    snap = store.snapshot()
    assert snap["available"] is False
    assert "hr_bpm" not in snap


def test_late_frames_never_overwrite_newer():
    store = MetricsState()
    assert store.update(frame(seq=10, ts=2000, hr_bpm=150))
    assert not store.update(frame(seq=9, ts=1000, hr_bpm=99))
    assert not store.update(frame(seq=10, ts=2000, hr_bpm=99))
    assert store.update(frame(seq=11, ts=3000, hr_bpm=151))
    assert store.latest.hr_bpm == 151


@pytest.mark.parametrize(
    ("speed", "pace"), [(1000 / 330, "5'30\""), (2.778, "6'00\""), (0.1, None), (0.0, None)]
)
def test_format_pace(speed, pace):
    assert format_pace(speed) == pace


def packet(data: bytes, topic: str = METRICS_TOPIC, identity: str = "athlete"):
    return SimpleNamespace(data=data, topic=topic, participant=SimpleNamespace(identity=identity))


def brain() -> CoachBrain:
    return CoachBrain(Athlete(athlete_id=str(uuid.uuid4())))


def listener(b: CoachBrain):
    inbox = AthleteInbox()
    inbox.attach(b, "athlete")
    return inbox.on_data


def test_listener_takes_metrics_only_from_the_athlete():
    b = brain()
    on_data = listener(b)
    raw = json.dumps(FULL).encode()
    on_data(packet(raw, topic="other"))
    on_data(packet(raw, identity="someone-else"))
    assert b.state.latest is None
    on_data(packet(raw))
    assert b.state.latest.seq == 128
    assert b.profile.name == "running"


def test_listener_drops_bad_frames():
    b = brain()
    on_data = listener(b)
    on_data(packet(b"not json"))
    on_data(packet(json.dumps(FULL | {"v": 2}).encode()))
    on_data(packet(b"[]"))
    assert b.state.latest is None


def test_session_meta_from_participant():
    athlete = str(uuid.uuid4())
    meta = SessionMeta(athlete, 900)
    assert read_session_meta(SimpleNamespace(metadata=meta.to_json())) == meta


def test_session_meta_fallback(monkeypatch):
    monkeypatch.setenv("COACHW_SESSION_MAX_MINUTES", "5")
    assert read_session_meta(SimpleNamespace(metadata="")).max_session_s == 300


def test_tool_result_is_plain_json():
    store = MetricsState()
    store.update(frame())
    data = json.loads(json.dumps(store.snapshot()))
    assert data["state"] == "running"
    assert data["hr_bpm"] == 152


def test_cap_says_goodbye_then_closes_the_room():
    calls = []

    class Handle:
        async def wait_for_playout(self):
            calls.append("playout")

    class Session:
        def generate_reply(self, **kwargs):
            calls.append("farewell")
            return Handle()

    class Ctx:
        async def delete_room(self):
            calls.append("delete_room")

        def shutdown(self, reason):
            calls.append("shutdown")

    asyncio.run(end_when_cap_reached(Ctx(), Session(), 0))
    assert calls == ["farewell", "playout", "delete_room", "shutdown"]


def test_prompt_forbids_guessing_numbers():
    assert "get_metrics" in INSTRUCTIONS
    assert "禁止估计" in INSTRUCTIONS
