import json
from datetime import UTC, datetime, timedelta
from types import SimpleNamespace

from coachw.agent.transcript import Transcript, classify, recent_conversation, transcript_dir


def item(role: str, text: str, interrupted: bool = False) -> SimpleNamespace:
    return SimpleNamespace(
        item=SimpleNamespace(role=role, text_content=text, interrupted=interrupted)
    )


def test_off_unless_configured(tmp_path):
    assert transcript_dir({}) is None
    assert transcript_dir({"COACHW_TRANSCRIPT_DIR": " "}) is None
    assert transcript_dir({"COACHW_TRANSCRIPT_DIR": str(tmp_path)}) == tmp_path


def test_classify_tells_the_athlete_from_system_prompts():
    assert classify("assistant", "加油") == "coach"
    assert classify("user", "我有点累") == "user"
    assert classify("user", "【教练提示】第 1 公里") == "cue"
    assert classify("user", "【运动状态】热身") == "status"
    assert classify("user", "【运动状态，仅供参考，不要回复】运动：跑步") == "status"
    assert classify("system", "x") is None
    assert classify(None, "x") is None


def test_writes_every_conversation_item_in_order(tmp_path):
    clock = lambda: datetime(2026, 11, 22, 6, 0, tzinfo=UTC)  # noqa: E731
    t = Transcript(tmp_path, room="coach-abc", athlete_id="a-1", clock=clock)
    t.on_item_added(item("user", "以后配速报慢一点"))
    t.on_item_added(item("assistant", "好的，记住了", interrupted=True))
    t.on_item_added(item("user", "【教练提示】第 1 公里"))
    t.on_item_added(item("assistant", "  "))
    t.on_item_added(SimpleNamespace(item=SimpleNamespace(role=None)))  # e.g. a function call

    assert t.path == tmp_path / "2026-11-22" / "coach-abc.jsonl"
    records = [json.loads(line) for line in t.path.read_text(encoding="utf-8").splitlines()]
    assert records[0] == {
        "type": "session",
        "ts": "2026-11-22T06:00:00+00:00",
        "room": "coach-abc",
        "athlete_id": "a-1",
    }
    assert [(r["type"], r["text"]) for r in records[1:]] == [
        ("user", "以后配速报慢一点"),
        ("coach", "好的，记住了"),
        ("cue", "【教练提示】第 1 公里"),
    ]
    assert records[2]["interrupted"] is True
    assert "interrupted" not in records[1]


def test_write_failure_does_not_raise(tmp_path):
    blocker = tmp_path / "file"
    blocker.write_text("")
    t = Transcript(blocker, room="r", athlete_id="a")  # a file where the directory should be
    t.add("user", "hello")
    assert t.lines == 0


def test_recent_conversation_is_this_athletes_last_words(tmp_path):
    now = datetime(2026, 11, 22, 7, 40, tzinfo=UTC)
    at = {"t": now - timedelta(minutes=45)}
    clock = lambda: at["t"]  # noqa: E731
    old = Transcript(tmp_path, room="coach-1", athlete_id="a-1", clock=clock)
    old.add("user", "太久以前")
    at["t"] = now - timedelta(minutes=10)
    first = Transcript(tmp_path, room="coach-1", athlete_id="a-1", clock=clock)
    first.add("user", "记一个改进点")
    first.add("cue", "【教练提示】第 1 公里")
    first.add("coach", "记下了")
    other = Transcript(tmp_path, room="coach-2", athlete_id="b-2", clock=clock)
    other.add("user", "别人的话")
    at["t"] = now - timedelta(minutes=1)
    later = Transcript(tmp_path, room="coach-3", athlete_id="a-1", clock=clock)
    later.add("user", "你在吗")

    lines = recent_conversation(tmp_path, "a-1", now, max_age_s=30 * 60, limit=10)
    assert lines == [("user", "记一个改进点"), ("coach", "记下了"), ("user", "你在吗")]
    assert recent_conversation(tmp_path, "a-1", now, max_age_s=30 * 60, limit=1) == [
        ("user", "你在吗")
    ]
    assert recent_conversation(tmp_path, "a-1", now, max_age_s=30 * 60, limit=0) == []
    assert recent_conversation(tmp_path / "none", "a-1", now, max_age_s=60, limit=5) == []


def test_recent_conversation_spans_multiple_days_and_skips_corrupt_lines(tmp_path):
    now = datetime(2026, 11, 23, 8, 0, tzinfo=UTC)
    day1 = datetime(2026, 11, 21, 9, 0, tzinfo=UTC)
    day2 = datetime(2026, 11, 22, 9, 0, tzinfo=UTC)
    t1 = Transcript(tmp_path, room="r1", athlete_id="a-1", clock=lambda: day1)
    t1.add("user", "第一天")
    t2 = Transcript(tmp_path, room="r2", athlete_id="a-1", clock=lambda: day2)
    t2.add("user", "第二天")
    # simulate a truncated write after a crash
    with t2.path.open("a", encoding="utf-8") as f:
        f.write('{"ts": "2026-11-22T09:00:01+00:00", "type": "coach"\n')
    t2.add("coach", "恢复后")

    lines = recent_conversation(tmp_path, "a-1", now, max_age_s=3 * 24 * 3600, limit=10)
    assert lines == [("user", "第一天"), ("user", "第二天"), ("coach", "恢复后")]
