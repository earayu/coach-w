import asyncio
import json
import uuid
from types import SimpleNamespace

from test_loop import Harness

from coachw.agent.cue_writer import SAY, CueWriter, conversation_of, numbers_in
from coachw.coach.brain import CoachBrain, Delivery
from coachw.coach.cue_queue import Cue
from coachw.coach.events import CoachEvent
from coachw.profiles.base import Athlete
from coachw.protocol import CuePriority
from coachw.session import SessionMeta

BIKE = (
    "完成第 3 公里，这一公里用时 4 分 22 秒，平均心率 127，平均步频每分钟 72 步。"
    "播报这一公里的用时，简短点评。"
)


def delivery(priority=CuePriority.MILESTONE, facts=BIKE) -> Delivery:
    cue = Cue("c1", CoachEvent("split:3", priority, facts, "split:3", 60, 30), 0, 30)
    return Delivery(cue, f"【教练提示】{facts}", interrupt=False, watch=None)


class Pen:
    def __init__(self, text):
        self.text, self.prompts = text, []

    async def __call__(self, system, prompt):
        self.prompts.append((system, prompt))
        return self.text


def writer(text, history=()):
    pen = Pen(text)
    brain = CoachBrain(Athlete(str(uuid.uuid4())))
    return CueWriter(brain, pen, lambda: history), pen


def test_the_written_line_is_what_the_coach_says():
    w, pen = writer("4 分 22 秒？步频才 72，你是不是在骑车？")
    out = asyncio.run(w.instructions_for(delivery()))
    assert out == SAY.format(text="4 分 22 秒？步频才 72，你是不是在骑车？")
    [(system, prompt)] = pen.prompts
    assert "常识" in system and "不要编数字" in system
    assert BIKE in prompt and "节点播报" in prompt


def test_the_writer_sees_the_recent_conversation():
    w, pen = writer("好", history=[("user", "我在骑车"), ("coach", "收到")])
    asyncio.run(w.instructions_for(delivery()))
    assert "用户：我在骑车" in pen.prompts[0][1] and "教练：收到" in pen.prompts[0][1]


def test_safety_cues_skip_the_writer():
    w, pen = writer("不该用到")
    d = delivery(CuePriority.EMERGENCY, "心率 193，已经连续 15 秒高于安全上限 184。")
    assert asyncio.run(w.instructions_for(d)) == d.instructions
    assert pen.prompts == []


def test_a_failed_writer_falls_back_to_the_plain_cue():
    w, _ = writer(None)
    d = delivery()
    assert asyncio.run(w.instructions_for(d)) == d.instructions


def test_a_line_with_numbers_the_coach_system_never_gave_is_not_used():
    w, _ = writer("配速每公里 4 分 22 秒，相当于时速 14 公里")
    d = delivery()
    assert asyncio.run(w.instructions_for(d)) == d.instructions
    assert numbers_in("每公里 4 分 22 秒，心率 127.5") == {"4", "22", "127.5"}


def test_conversation_skips_cues_and_status():
    items = [
        SimpleNamespace(type="message", role="user", text_content="【教练提示】第 1 公里"),
        SimpleNamespace(type="message", role="user", text_content="我累了"),
        SimpleNamespace(type="function_call", role=None, text_content=None),
        SimpleNamespace(type="message", role="assistant", text_content="慢一点"),
        SimpleNamespace(type="message", role="user", text_content="【运动状态】跑步"),
    ]
    assert conversation_of(items) == [("user", "我累了"), ("coach", "慢一点")]
    assert conversation_of(items, limit=0) == []


def test_quote_only_writer_output_falls_back_and_aclose_runs_hook():
    closed = []

    async def close():
        closed.append(True)

    brain = CoachBrain(Athlete(str(uuid.uuid4())))
    w = CueWriter(brain, Pen('""'), close=close)
    d = delivery()
    assert asyncio.run(w.instructions_for(d)) == d.instructions
    asyncio.run(w.aclose())
    assert closed == [True]


def test_the_loop_says_what_the_writer_wrote():
    class Upper:
        async def instructions_for(self, d):
            return "WRITTEN " + d.instructions

    h = Harness()
    h.loop.writer = Upper()
    h.run.run(3)
    [start] = h.session.replies
    assert start.startswith("WRITTEN 【教练提示】")


def test_session_meta_carries_the_cue_writer():
    meta = SessionMeta(str(uuid.uuid4()), 600, "qwen3.8-flash")
    assert SessionMeta.from_json(meta.to_json()) == meta
    old = json.dumps({"athlete_id": str(uuid.uuid4()), "max_session_s": 60})
    assert SessionMeta.from_json(old).cue_writer == ""


def test_writer_drops_verbatim_duplicate_of_last_coach_line():
    w, _ = writer("抱歉，我记错了。", history=[("coach", "抱歉我记错了")])
    opt = Delivery(
        Cue(
            "c2",
            CoachEvent(
                "check_in", CuePriority.COMPANION, "检查", "check_in", 60, 15, optional=True
            ),
            0,
            15,
        ),
        "【教练提示】检查",
        interrupt=False,
        watch=None,
    )
    assert asyncio.run(w.instructions_for(opt)) is None
