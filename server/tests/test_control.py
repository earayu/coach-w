"""The coach pauses, resumes and ends the workout on the watch (spec 7.6, COCH-22)."""

import asyncio
import json
from types import SimpleNamespace

from test_agent import FULL, FakeParticipant

from coachw.agent.coach import INSTRUCTIONS, CoachAgent
from coachw.agent.voice_start import control_heard
from coachw.agent.worker import ask_phone_to_control
from coachw.coach.brain import CoachBrain
from coachw.profiles.base import Athlete
from coachw.protocol import MetricsFrame


def test_the_athletes_words_pause_and_resume():
    assert control_heard("没开始跑，你帮你帮我暂停吧。", paused=False) == "pause"
    assert control_heard("能不能帮我暂停一下", paused=False) == "pause"
    assert control_heard("好了，继续跑", paused=True) == "resume"
    assert control_heard("取消暂停", paused=True) == "resume"
    assert control_heard("继续跑", paused=False) is None
    assert control_heard("暂停", paused=True) is None


def test_questions_refusals_and_feedback_do_not_pause():
    for text in (
        "先别暂停",
        "暂停了吗",
        "是不是暂停了",
        "记录一下产品功能，教练应该能够帮我暂停",
        "待会儿暂停一下",
    ):
        assert control_heard(text, paused=False) is None, text


def control_agent(asked: list[str]) -> CoachAgent:
    async def control(action: str) -> dict:
        asked.append(action)
        return {"ok": True}

    return CoachAgent(CoachBrain(Athlete(athlete_id="a")), control=control)


def test_control_needs_a_running_workout_and_asks_once():
    asked: list[str] = []
    agent = control_agent(asked)
    idle = json.loads(asyncio.run(agent.pause_workout(None)))
    assert idle["ok"] is False and asked == []
    agent.brain.on_frame(MetricsFrame.from_dict(FULL))
    assert json.loads(asyncio.run(agent.pause_workout(None)))["ok"] is True
    # the tool and the athlete's words both heard the same "pause"
    asyncio.run(agent.request_control("pause"))
    assert json.loads(asyncio.run(agent.end_workout(None)))["ok"] is True
    assert asked == ["pause", "end"]
    assert asyncio.run(agent.request_control("explode"))["ok"] is False


def test_control_asks_the_athletes_phone():
    phone = FakeParticipant(json.dumps({"ok": True}))
    room = SimpleNamespace(local_participant=phone)
    assert asyncio.run(ask_phone_to_control(room, "athlete-1", "pause"))["ok"] is True
    [call] = phone.calls
    assert call["method"] == "coach.control" and json.loads(call["payload"]) == {"action": "pause"}
    old_app = SimpleNamespace(local_participant=FakeParticipant(error=RuntimeError()))
    assert asyncio.run(ask_phone_to_control(old_app, "a", "end"))["ok"] is False


def test_the_coach_is_told_it_can_operate_the_watch():
    for tool in ("pause_workout", "resume_workout", "end_workout", "remember_request"):
        assert tool in INSTRUCTIONS
    assert "不能撤回" in INSTRUCTIONS
