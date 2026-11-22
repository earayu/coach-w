import json
from datetime import UTC, datetime
from types import SimpleNamespace

from coachw.agent.transcript import Transcript, classify, transcript_dir


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
