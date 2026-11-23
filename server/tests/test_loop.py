import asyncio
import json
import uuid

from synth import T0_MS, Clock, Runner

from coachw.agent.coach import CoachAgent, profile_tool
from coachw.agent.loop import SUMMARY_EVERY_S, CoachLoop
from coachw.coach.brain import CoachBrain
from coachw.profiles.base import Athlete
from coachw.profiles.running import ADJUST_TARGET_PACE


class FakeSession:
    def __init__(self):
        self.user_state = "listening"
        self.agent_state = "listening"
        self.replies: list[str] = []
        self.interrupts = 0

    def generate_reply(self, *, user_input):
        self.replies.append(user_input)

    def interrupt(self):
        self.interrupts += 1


class FakeAgent:
    def __init__(self):
        self.profiles = 0
        self.statuses: list[str] = []

    async def apply_profile(self):
        self.profiles += 1

    async def inject_status(self, text):
        self.statuses.append(text)


class Harness:
    def __init__(self):
        self.clock = Clock()
        self.brain = CoachBrain(
            Athlete(str(uuid.uuid4())),
            clock=self.clock,
            wall_ms=lambda: T0_MS + int(self.clock.now * 1000),
        )
        self.session = FakeSession()
        self.agent = FakeAgent()
        self.published = []

        async def publish(cue):
            self.published.append(cue)

        self.loop = CoachLoop(self.brain, self.agent, self.session, publish, clock=self.clock)
        self.run = Runner(self.brain.on_frame, self.clock, on_tick=self.step)

    def step(self):
        asyncio.run(self.loop.step())


def test_profile_is_applied_once_per_load():
    h = Harness()
    h.step()
    assert h.agent.profiles == 0
    h.run.run(10)
    assert h.agent.profiles == 1


def test_cue_becomes_a_reply_and_a_watch_cue():
    h = Harness()
    h.run.run(3)
    [start] = h.session.replies
    assert start.startswith("【教练提示】") and "只使用这里给出的数字" in start
    [cue] = h.published
    assert cue.kind == "start" and cue.haptic == "start"


def test_emergency_interrupts_a_speaking_coach():
    h = Harness()
    h.run.run(120, hr=150)
    h.session.agent_state = "speaking"
    replies = len(h.session.replies)
    h.run.run(30, hr=190)
    assert h.session.interrupts == 1
    assert len(h.session.replies) == replies + 1
    assert h.published[-1].priority == "emergency"


def test_nothing_but_emergencies_while_the_coach_thinks():
    h = Harness()
    h.session.agent_state = "thinking"
    h.run.run(10)
    assert h.session.replies == []


def test_status_summary_is_injected_periodically_when_idle():
    h = Harness()
    h.run.run(SUMMARY_EVERY_S + 1)
    assert len(h.agent.statuses) == 1
    assert h.agent.statuses[0].startswith("【运动状态")
    h.session.user_state = "speaking"
    h.run.run(SUMMARY_EVERY_S + 1)
    assert len(h.agent.statuses) == 1
    h.session.user_state = "listening"
    h.run.run(2)
    assert len(h.agent.statuses) == 2


def test_status_is_refreshed_when_the_athlete_starts_speaking():
    h = Harness()
    h.run.run(20, hr=140)
    asyncio.run(h.loop.athlete_started_speaking())
    assert len(h.agent.statuses) == 1 and "心率 140" in h.agent.statuses[-1]
    # fragments of one sentence do not each rewrite it
    asyncio.run(h.loop.athlete_started_speaking())
    assert len(h.agent.statuses) == 1
    h.run.run(5, hr=152)
    asyncio.run(h.loop.athlete_started_speaking())
    assert len(h.agent.statuses) == 2 and "心率 152" in h.agent.statuses[-1]


def test_publish_failure_does_not_break_the_loop():
    h = Harness()

    async def broken(cue):
        raise ConnectionError

    h.loop.publish_cue = broken
    h.run.run(3)
    assert len(h.session.replies) == 1


def test_profile_tool_wraps_the_brain():
    h = Harness()
    h.run.run(1)
    tool = profile_tool(h.brain, ADJUST_TARGET_PACE)
    assert tool.info.name == "adjust_target_pace"
    assert tool.info.raw_schema["parameters"]["required"] == ["pace_min", "pace_sec"]
    result = json.loads(asyncio.run(tool(raw_arguments={"pace_min": 5, "pace_sec": 15})))
    assert result["target_pace_per_km"] == "5'15\""


def test_coach_agent_tools():
    h = Harness()
    agent = CoachAgent(h.brain)
    names = {t.info.name for t in agent.tools}
    assert {"get_metrics", "get_progress", "set_quiet", "end_workout_summary"} <= names
    assert "adjust_target_pace" not in names  # profile tools arrive with the profile
    h.run.run(5, hr=144)
    assert json.loads(asyncio.run(agent.get_metrics(None)))["hr_bpm"] == 144
    assert json.loads(asyncio.run(agent.get_progress(None)))["available"] is True
    assert json.loads(asyncio.run(agent.set_quiet(None, 99)))["minutes"] == 30
    assert json.loads(asyncio.run(agent.end_workout_summary(None)))["available"] is True


def test_status_rides_at_the_end_of_the_instructions():
    # COCH-18: Qwen ignored a mid-conversation system item; it follows the session instructions
    h = Harness()
    h.run.run(5, hr=144)
    agent = CoachAgent(h.brain)
    asyncio.run(agent.apply_profile())
    asyncio.run(agent.inject_status("【运动状态】心率 144"))
    asyncio.run(agent.inject_status("【运动状态】心率 150"))
    assert agent.instructions.endswith("【运动状态】心率 150")
    assert "心率 144" not in agent.instructions
    assert h.brain.profile.prompt in agent.instructions
    asyncio.run(agent.apply_profile())
    assert agent.instructions.endswith("【运动状态】心率 150")
    # a second profile load replaces the fragment instead of stacking it
    assert agent.instructions.count(h.brain.profile.prompt) == 1
