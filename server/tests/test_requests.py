"""The athlete's requests, the coach's wake-ups and its sense of time (spec 4.2.2, COCH-22)."""

import asyncio
import json
from datetime import UTC, datetime, timedelta

from test_brain import Session

from coachw.agent.coach import CoachAgent
from coachw.agent.cue_writer import CueWriter
from coachw.agent.memory import AthleteMemory
from coachw.coach.requests import MIN_EVERY_M, MIN_EVERY_S, Requests, parse_distance_m
from coachw.protocol import CuePriority


def test_timed_requests_come_due_and_repeat():
    r = Requests()
    every_min = r.add("报心率", every_s=60, lasting=False, now=0)
    r.add("别叫我加油", every_s=None, lasting=True, now=0)
    assert r.due(30) == []
    assert r.due(60) == [every_min]
    assert r.due(61) == [] and r.due(120) == [every_min]
    assert r.add("报配速", every_s=5, lasting=False, now=0).every_s == MIN_EVERY_S
    assert r.add("  ", every_s=None, lasting=False, now=0) is None
    assert [x.describe() for x in r.items][:2] == [
        "#1「报心率」（每 1 分钟）",
        "#2「别叫我加油」（长期）",
    ]


def test_a_request_is_said_when_due_with_the_current_readings():
    s = Session()
    s.run.run(5, hr=150)
    s.brain.add_request("报心率", every_s=60, lasting=False)
    s.run.run(120, hr=150, speed=1.5)
    due = [d for d in s.deliveries if d.cue.event.kind == "request"]
    assert len(due) == 2
    assert "报心率" in due[0].instructions and "心率 150" in due[0].instructions
    assert due[0].cue.priority is CuePriority.MILESTONE


def test_requests_wait_while_paused():
    from coachw.protocol import WorkoutState

    s = Session()
    s.run.run(5)
    s.brain.add_request("报心率", every_s=60, lasting=False)
    s.run.run(120, state=WorkoutState.PAUSED)
    assert not [d for d in s.deliveries if d.cue.event.kind == "request"]


def test_the_status_carries_the_time_and_the_requests():
    s = Session()
    assert "现在时间" in s.brain.status_summary()
    s.run.run(5)
    s.brain.add_request("每公里提醒我喝水", every_s=None, lasting=False)
    status = s.brain.status_summary()
    assert "现在时间" in status and "用户交代过：#1「每公里提醒我喝水」" in status


def test_check_ins_only_with_a_writer_and_after_silence():
    s = Session()
    s.run.run(300, speed=1.5)
    assert not [d for d in s.deliveries if d.cue.event.kind == "check_in"]
    s = Session()
    s.brain.check_in_s = 75
    s.run.run(300, speed=1.5)
    checks = [d for d in s.deliveries if d.cue.event.kind == "check_in"]
    assert checks and all(d.optional for d in checks)


def check_in_delivery():
    s = Session()
    s.brain.check_in_s = 75
    s.run.run(300, speed=1.5)
    return s, next(d for d in s.deliveries if d.cue.event.kind == "check_in")


def test_the_writer_may_answer_a_check_in_with_nothing():
    s, delivery = check_in_delivery()

    async def skip(_system, _prompt):
        return "SKIP"

    async def line(_system, _prompt):
        return "上坡了，步子收小一点。"

    async def fail(_system, _prompt):
        return None

    assert asyncio.run(CueWriter(s.brain, skip).instructions_for(delivery)) is None
    assert asyncio.run(CueWriter(s.brain, fail).instructions_for(delivery)) is None
    said = asyncio.run(CueWriter(s.brain, line).instructions_for(delivery))
    assert "上坡了" in said


class Clock:
    def __init__(self, now: datetime) -> None:
        self.now = now

    def __call__(self) -> datetime:
        return self.now


def test_memory_keeps_lasting_requests_and_recent_workout_ones(tmp_path):
    clock = Clock(datetime(2026, 11, 24, 12, 0, tzinfo=UTC))
    memory = AthleteMemory(tmp_path, "athlete-1", clock=clock)
    s = Session()
    s.brain.add_request("报心率", every_s=60, lasting=False)
    s.brain.add_request("别叫我加油", every_s=None, lasting=True)
    memory.save(s.brain.requests.items)
    clock.now += timedelta(hours=1)
    assert [r.text for r in AthleteMemory(tmp_path, "athlete-1", clock=clock).load()] == [
        "报心率",
        "别叫我加油",
    ]
    clock.now += timedelta(hours=3)
    later = AthleteMemory(tmp_path, "athlete-1", clock=clock).load()
    assert [r.text for r in later] == ["别叫我加油"]
    assert AthleteMemory(tmp_path, "someone-else", clock=clock).load() == []


def test_the_coach_tools_remember_forget_and_note_feedback(tmp_path):
    s = Session()
    memory = AthleteMemory(tmp_path, "athlete-1")
    agent = CoachAgent(s.brain, keeps_transcript=True, memory=memory)
    ok = json.loads(asyncio.run(agent.remember_request(None, "报心率", every_minutes=1)))
    assert ok["ok"] and ok["every_s"] == 60
    assert [r.text for r in AthleteMemory(tmp_path, "athlete-1").load()] == ["报心率"]
    assert json.loads(asyncio.run(agent.forget_request(None, 0)))["ok"] is True
    assert AthleteMemory(tmp_path, "athlete-1").load() == []
    assert json.loads(asyncio.run(agent.note_feedback(None, "教练应该能帮我暂停")))["ok"]
    [day] = (tmp_path / "feedback").iterdir()
    record = json.loads(day.read_text(encoding="utf-8"))
    assert record["text"] == "教练应该能帮我暂停" and record["athlete_id"] == "athlete-1"
    no_memory = CoachAgent(s.brain)
    assert json.loads(asyncio.run(no_memory.note_feedback(None, "x")))["ok"] is False


def test_distance_requests_parse_persist_and_fold_into_splits(tmp_path):
    assert parse_distance_m("每公里报心率") == 1000.0
    assert parse_distance_m("每两公里提醒我喝水") == 2000.0
    assert parse_distance_m("每500米报配速") == 500.0
    assert parse_distance_m("每分钟报心率") is None

    r = Requests()
    dreq = r.add("每公里报心率", every_m=1000, lasting=False, now=0, distance_m=1200)
    assert dreq.next_m == 2000.0
    assert dreq.describe() == "#1「每公里报心率」（每 1 公里）"
    assert r.due(10, distance_m=1999) == []
    assert r.due(11, distance_m=2000) == [dreq]
    assert dreq.next_m == 3000.0
    assert r.add("short", every_m=10, lasting=False, now=0).every_m == MIN_EVERY_M

    # Tool infers every_km from text even if the model leaves every_km=0, and persists it.
    s = Session()
    memory = AthleteMemory(tmp_path, "athlete-d")
    agent = CoachAgent(s.brain, keeps_transcript=True, memory=memory)
    res = json.loads(asyncio.run(agent.remember_request(None, "每公里报心率")))
    assert res["ok"] and res["every_m"] == 1000.0
    loaded = AthleteMemory(tmp_path, "athlete-d").load()
    assert len(loaded) == 1 and loaded[0].every_m == 1000.0

    # At 1 km, the per-km request folds into split:1 rather than emitting two separate cues.
    s.run.run(340, speed=1000 / 330, hr=155)
    splits = [d for d in s.deliveries if d.cue.event.kind == "split:1"]
    requests = [d for d in s.deliveries if d.cue.event.kind == "request"]
    assert len(splits) == 1 and "每公里报心率" in splits[0].instructions
    assert requests == []

    # Non-split distance request (every 500m) fires its own request cue at 500m.
    s2 = Session()
    s2.brain.add_request("提醒喝水", every_m=500, lasting=False)
    s2.run.run(200, speed=3.0, hr=150)  # 600m
    reqs = [d for d in s2.deliveries if d.cue.event.kind == "request"]
    assert len(reqs) == 1 and "提醒喝水" in reqs[0].instructions


def test_check_in_backs_off_when_athlete_is_silent_and_resets_when_speaking():
    s = Session()
    s.brain.check_in_s = 75
    s.run.run(700, speed=1.5)
    checks = [d.cue.created_at for d in s.deliveries if d.cue.event.kind == "check_in"]
    assert len(checks) >= 3
    gaps = [b - a for a, b in zip(checks, checks[1:], strict=False)]
    assert gaps[0] >= 150 and gaps[1] >= 300

    # Athlete speaks -> backoff resets back to 75s.
    s.brain.note_athlete_spoke()
    spoke_at = s.clock.now
    s.run.run(100, speed=1.5)
    after = [
        d.cue.created_at
        for d in s.deliveries
        if d.cue.event.kind == "check_in" and d.cue.created_at > spoke_at
    ]
    assert after and after[0] - spoke_at < 90
