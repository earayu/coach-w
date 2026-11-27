"""Deterministic product feedback capture and deduplication (COCH-22)."""

import json
from datetime import UTC, datetime, timedelta

from coachw.agent.feedback import FeedbackCatcher
from coachw.agent.memory import AthleteMemory


def test_catcher_captures_inline_feedback():
    c = FeedbackCatcher()
    assert c.heard("记个产品改进点，跑步的时候老是重复报公里数", 10.0) == (
        "记个产品改进点，跑步的时候老是重复报公里数"
    )
    assert c.heard("给开发团队提个建议，上坡的时候别老催我提速", 20.0) == (
        "给开发团队提个建议，上坡的时候别老催我提速"
    )


def test_catcher_captures_retrospective_and_prospective_bare_markers():
    c = FeedbackCatcher()
    assert c.heard("你刚刚连续报了三次前几公里的用时", 10.0) is None
    assert c.heard("这是一个产品改进点", 14.0) == "你刚刚连续报了三次前几公里的用时"

    assert c.heard("我提一个产品改进点", 50.0) is None
    assert c.heard("嗯", 51.0) is None
    assert c.heard("我希望教练能看到我以前跑的历史记录", 54.0) == (
        "我希望教练能看到我以前跑的历史记录"
    )


def test_catcher_ignores_negations_and_meta_questions():
    c = FeedbackCatcher()
    for text in (
        "今天没有什么产品改进点",
        "刚才那个改进点你记下来了吗",
        "我现在心率多少",
        "   ",
    ):
        assert c.heard(text, 10.0) is None, text


def test_memory_deduplicates_similar_feedback_within_window(tmp_path):
    now = [datetime(2026, 11, 27, 6, 0, tzinfo=UTC)]
    memory = AthleteMemory(tmp_path, "athlete-1", clock=lambda: now[0])
    assert memory.note_feedback("记个产品改进点，跑步的时候重复播报公里数")
    # Model calls note_feedback a few seconds later with a paraphrased summary.
    now[0] += timedelta(seconds=5)
    assert memory.note_feedback("跑步时重复播报公里数")
    # A genuinely different feedback note right after is still kept.
    now[0] += timedelta(seconds=10)
    assert memory.note_feedback("希望增加查看历史运动记录的功能")
    [day] = (tmp_path / "feedback").iterdir()
    rows = [json.loads(line) for line in day.read_text(encoding="utf-8").splitlines()]
    assert len(rows) == 2
    assert "重复播报公里数" in rows[0]["text"]
    assert "历史运动记录" in rows[1]["text"]
