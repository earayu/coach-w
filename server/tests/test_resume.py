"""A new coach session carries on a workout an earlier one coached (`coach.resume`, spec 7.4)."""

import asyncio
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_brain import Session

from coachw.agent import worker
from coachw.agent.coach import GREETING
from coachw.agent.worker import AthleteInbox, greeting_for
from coachw.protocol import METRICS_TOPIC, RESUME_TOPIC, CoachResume

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "fixtures"
RESUME = json.loads((FIXTURES / "coach_resume_v1_full.json").read_text())


def resume(**patch) -> CoachResume:
    return CoachResume.from_dict(RESUME | patch)


def resumed_session(activity="running", **patch) -> Session:
    s = Session(activity=activity)
    assert s.brain.resume(resume(activity=activity, **patch))
    s.run.elapsed = RESUME["elapsed_s"]
    s.run.distance = RESUME["distance_m"]
    return s


def test_resume_continues_splits_without_repeating_the_start():
    s = resumed_session()
    assert s.brain.profile.name == "running"
    assert [x.index for x in s.brain.state.splits] == [1, 2, 3]
    s.run.run(60 * 5, speed=1000 / 330, hr=150)  # crosses 4 km at ~ 1310 s
    kinds = s.kinds()
    assert "start" not in kinds
    assert [k for k in kinds if k.startswith("split:")] == ["split:4"]
    split4 = s.brain.state.splits[-1]
    assert split4.index == 4
    assert split4.duration_s == pytest.approx(1260.5 + 154.9 * 330 / 1000 - 965.8, abs=2)


def test_resume_greeting_says_where_the_workout_is():
    s = resumed_session()
    text = s.brain.resume_greeting()
    assert text.startswith("【教练提示】")
    assert "用时 21 分" in text and "3.85 公里" in text and "跑步进行中" in text


def test_no_resume_no_special_greeting():
    assert Session().brain.resume_greeting() is None


def test_resume_seeds_whole_workout_means():
    s = resumed_session()
    s.run.run(10, hr=160)
    summary = s.brain.end_workout_summary()
    assert summary["avg_hr_bpm"] == pytest.approx((151.3 * 1180 + 160 * 10) / 1190, abs=0.01)
    assert [x["index"] for x in summary["splits"]] == [1, 2, 3]


def test_resume_is_applied_once_and_never_over_first_hand_splits():
    s = Session()
    s.run.run(400, speed=1000 / 300)  # one split of its own
    assert not s.brain.resume(resume(activity="cycling"))
    assert s.brain.resume(resume())
    assert [x.index for x in s.brain.state.splits] == [1]
    assert not s.brain.resume(resume())


def test_resume_for_a_bike_uses_5_km_splits():
    marks = [300.0 * i for i in range(1, 12)]
    s = Session(activity="cycling")
    s.brain.resume(resume(activity="cycling", km_marks_s=marks, elapsed_s=3400.0))
    assert [(x.index, x.elapsed_s) for x in s.brain.state.splits] == [(1, 1500.0), (2, 3000.0)]


def test_resumed_time_marks_are_not_announced_late():
    s = resumed_session(activity="yoga", km_marks_s=[], distance_m=None)
    s.run.distance = 0
    s.run.run(5 * 60, speed=None, hr=120)  # 1260 → 1560 s: nothing new
    assert not [k for k in s.kinds() if k.startswith("time:")]
    s.run.run(5 * 60, speed=None, hr=120)  # past 1800 s
    assert [k for k in s.kinds() if k.startswith("time:")] == ["time:3"]
    assert "start" not in s.kinds()


def packet(data: dict, topic: str, identity: str = "athlete"):
    return SimpleNamespace(
        data=json.dumps(data).encode(), topic=topic, participant=SimpleNamespace(identity=identity)
    )


def test_inbox_holds_packets_until_the_athlete_is_known():
    s = Session()
    inbox = AthleteInbox()
    inbox.on_data(packet(RESUME, RESUME_TOPIC))
    inbox.on_data(packet(RESUME, "unrelated"))
    inbox.attach(s.brain, "athlete")
    assert inbox.resumed.is_set()
    assert s.brain.resumed is not None


def test_inbox_ignores_resume_from_someone_else():
    s = Session()
    inbox = AthleteInbox()
    inbox.attach(s.brain, "athlete")
    inbox.on_data(packet(RESUME, RESUME_TOPIC, identity="intruder"))
    inbox.on_data(packet(RESUME | {"v": 2}, RESUME_TOPIC))
    assert s.brain.resumed is None and not inbox.resumed.is_set()


def test_inbox_routes_metrics():
    s = Session()
    inbox = AthleteInbox()
    inbox.attach(s.brain, "athlete")
    frame = {"v": 1, "seq": 1, "ts": 1, "activity": "walking", "state": "running", "elapsed_s": 1}
    inbox.on_data(packet(frame, METRICS_TOPIC))
    assert s.brain.profile.name == "walking"


def test_greeting_waits_for_resume_then_falls_back(monkeypatch):
    monkeypatch.setattr(worker, "RESUME_WAIT_S", 0.01)
    s = Session()
    inbox = AthleteInbox()
    inbox.attach(s.brain, "athlete")
    assert asyncio.run(greeting_for(s.brain, inbox)) == GREETING
    inbox.on_data(packet(RESUME, RESUME_TOPIC))
    assert asyncio.run(greeting_for(s.brain, inbox)).startswith("【教练提示】")


def test_starting_a_new_workout_clears_previous_resume_state():
    s = resumed_session()
    assert s.brain.resumed is not None
    # workout time rewinds -> new workout begins in the same voice session
    s.run.elapsed = 0
    s.run.distance = 0
    s.run.run(3)
    assert s.brain.resumed is None
    assert s.brain.resume_greeting() is None
