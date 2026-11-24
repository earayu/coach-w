"""The athlete's own words start the workout (spec 7.6)."""

import asyncio

from coachw.agent.coach import CoachAgent
from coachw.agent.voice_start import VoiceStart
from coachw.coach.brain import CoachBrain
from coachw.profiles.base import Athlete
from coachw.profiles.registry import activity_spoken_in


def test_activities_are_named_in_the_athletes_words():
    assert activity_spoken_in("好，我们开始跑步吧") == "running"
    assert activity_spoken_in("今天出去散散步") == "walking"
    assert activity_spoken_in("今天出去散步") == "walking"
    assert activity_spoken_in("去爬山") == "hiking"
    assert activity_spoken_in("骑车去，路上跑一段") == "cycling"
    assert activity_spoken_in("今天天气不错") is None


def test_a_clear_start_starts_the_named_activity():
    v = VoiceStart()
    assert v.heard("好，我们开始跑步吧") == "running"
    assert VoiceStart().heard("出发，骑起来") == "cycling"


def test_start_without_an_activity_uses_the_one_mentioned_before():
    v = VoiceStart()
    assert v.heard("今天想轻松跑个五公里") is None
    assert v.heard("好了，开始吧") == "running"
    assert VoiceStart().heard("开始吧") is None


def test_not_yet_and_questions_do_not_start():
    v = VoiceStart()
    for said in (
        "先别开始，我系个鞋带",
        "等一下再开始跑",
        "还没开始跑呢",
        "开始跑步了吗",
        "我不想跑了",
    ):
        assert v.heard(said) is None, said


def test_tool_and_words_asking_together_start_once():
    calls: list[str] = []

    async def start(activity: str) -> dict:
        calls.append(activity)
        return {"ok": True}

    agent = CoachAgent(CoachBrain(Athlete(athlete_id="a")), start=start)

    async def both() -> list[dict]:
        return [await agent.request_start("running"), await agent.request_start("running")]

    first, second = asyncio.run(both())
    assert first == {"ok": True} and second["ok"] is True
    assert calls == ["running"]


def test_a_failed_start_can_be_asked_again():
    calls: list[str] = []

    async def start(activity: str) -> dict:
        calls.append(activity)
        return {"ok": False, "reason": "phone did not answer"}

    agent = CoachAgent(CoachBrain(Athlete(athlete_id="a")), start=start)
    asyncio.run(agent.request_start("running"))
    asyncio.run(agent.request_start("running"))
    assert calls == ["running", "running"]
