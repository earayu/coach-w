"""Replies to turns nobody said, and the model's placeholders (COCH-22)."""

from types import SimpleNamespace

from coachw.agent.transcript import classify
from coachw.agent.turns import RETRY, TurnGuard, is_empty_turn, is_placeholder
from coachw.providers.qwen import is_benign_error


class Handle:
    def __init__(self) -> None:
        self.interrupted = False
        self.finished = False

    def done(self) -> bool:
        return self.finished

    def interrupt(self, *, force: bool = False) -> None:
        self.interrupted = force


class Session:
    def __init__(self) -> None:
        self.replies: list[str] = []
        self.handlers: dict[str, object] = {}

    def on(self, event: str, handler) -> None:
        self.handlers[event] = handler

    def generate_reply(self, *, user_input: str) -> None:
        self.replies.append(user_input)


class Clock:
    def __init__(self) -> None:
        self.now = 100.0

    def __call__(self) -> float:
        return self.now


def guard():
    clock = Clock()
    session = Session()
    g = TurnGuard(session, clock=clock)
    g.attach()
    return g, session, clock


def speech(user_initiated: bool = False):
    handle = Handle()
    return handle, SimpleNamespace(user_initiated=user_initiated, speech_handle=handle)


def said(text: str, final: bool = True):
    return SimpleNamespace(transcript=text, is_final=final)


def coach_line(text: str, interrupted: bool = False):
    return SimpleNamespace(
        item=SimpleNamespace(role="assistant", text_content=text, interrupted=interrupted)
    )


def test_empty_and_placeholder_text():
    assert is_empty_turn("") and is_empty_turn(" 。，") and not is_empty_turn("嗯。")
    assert is_placeholder("[ERROR: Failed to create agent for this item]")
    assert is_placeholder("[工具调用]") and not is_placeholder("好，收到")


def test_a_reply_to_noise_is_dropped():
    g, _, clock = guard()
    handle, ev = speech()
    g.on_speech_created(ev)
    clock.now += 1
    g.on_user_input(said(""))
    assert handle.interrupted and g.dropped == 1


def test_a_reply_to_words_and_the_coach_systems_own_lines_stay():
    g, _, _ = guard()
    handle, ev = speech()
    g.on_speech_created(ev)
    g.on_user_input(said("我现在心率多少"))
    g.on_user_input(said("", final=False))
    assert not handle.interrupted
    cue, ev = speech(user_initiated=True)
    g.on_speech_created(ev)
    g.on_user_input(said(""))
    assert not cue.interrupted


def test_an_empty_transcript_before_the_reply_still_drops_it():
    g, _, clock = guard()
    g.on_user_input(said(""))
    clock.now += 1
    handle, ev = speech()
    g.on_speech_created(ev)
    assert handle.interrupted
    later, ev = speech()
    g.on_speech_created(ev)
    assert not later.interrupted


def test_noise_that_cut_the_coach_off_lets_it_finish():
    g, _, _ = guard()
    g.on_item_added(coach_line("第三公里跑完了，用时", interrupted=True))
    handle, ev = speech()
    g.on_speech_created(ev)
    g.on_user_input(said(""))
    assert not handle.interrupted


def test_a_placeholder_reply_is_asked_again_once_in_a_while():
    g, session, clock = guard()
    g.on_item_added(coach_line("[ERROR: Failed to create agent for this item]"))
    g.on_item_added(coach_line("[工具调用]"))
    assert session.replies == [RETRY]
    clock.now += 30
    g.on_item_added(coach_line("[工具调用]"))
    assert session.replies == [RETRY, RETRY]


def test_placeholders_are_not_kept_as_what_the_coach_said():
    assert classify("assistant", "[工具调用]") == "glitch"
    assert classify("assistant", "好，开始吧") == "coach"


def test_only_the_item_already_exists_error_is_ignored():
    exists = {"error": {"code": "invalid_value", "message": "Item already exists with id: x"}}
    assert is_benign_error(exists)
    assert not is_benign_error({"error": {"code": "invalid_value", "message": "bad audio"}})
    assert not is_benign_error({"error": "x"})
