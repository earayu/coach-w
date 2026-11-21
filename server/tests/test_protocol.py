import json
from pathlib import Path

import pytest

from coachw.protocol import (
    CoachCue,
    CuePriority,
    Haptic,
    MetricsFrame,
    ProtocolError,
    WorkoutState,
)

FIXTURES = Path(__file__).resolve().parents[2] / "protocol" / "fixtures"


def load(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


def test_full_fixture():
    frame = MetricsFrame.from_dict(load("metrics_frame_v1_full.json"))
    assert frame.seq == 128
    assert frame.activity == "running"
    assert frame.state is WorkoutState.RUNNING
    assert frame.phone_ts == 1763726400180
    assert frame.hr_bpm == 152
    assert frame.gct_ms == 248


def test_missing_metrics_stay_none():
    frame = MetricsFrame.from_dict(load("metrics_frame_v1_minimal.json"))
    assert frame.state is WorkoutState.PAUSED
    assert frame.hr_bpm is None
    assert frame.lat is None


@pytest.mark.parametrize(
    "path", sorted(FIXTURES.glob("metrics_frame_*.json")), ids=lambda p: p.name
)
def test_every_fixture_round_trips(path: Path):
    data = json.loads(path.read_text())
    frame = MetricsFrame.from_dict(data)
    assert frame.to_dict() == data
    assert MetricsFrame.from_dict(frame.to_dict()) == frame


def test_unknown_fields_are_ignored():
    data = load("metrics_frame_v1_minimal.json") | {"future_field": 1}
    assert MetricsFrame.from_dict(data).seq == 1


@pytest.mark.parametrize(
    "patch",
    [{"v": 2}, {"state": "sprinting"}],
)
def test_rejects_bad_frames(patch: dict):
    with pytest.raises(ProtocolError):
        MetricsFrame.from_dict(load("metrics_frame_v1_minimal.json") | patch)


@pytest.mark.parametrize("raw", ["[]", "1", "null", '"frame"'])
def test_rejects_non_objects(raw: str):
    with pytest.raises(ProtocolError):
        MetricsFrame.from_json(raw)


def test_rejects_missing_required():
    data = load("metrics_frame_v1_minimal.json")
    del data["elapsed_s"]
    with pytest.raises(ProtocolError):
        MetricsFrame.from_dict(data)


def test_fixtures_are_named_after_their_message():
    names = [p.name for p in FIXTURES.glob("*.json")]
    assert names
    assert all(n.startswith(("metrics_frame_", "coach_cue_")) for n in names)


def test_cue_full_fixture():
    cue = CoachCue.from_dict(load("coach_cue_v1_full.json"))
    assert cue.id == "cue-000017"
    assert cue.priority is CuePriority.EMERGENCY
    assert cue.haptic is Haptic.FAILURE
    assert cue.expires_at - cue.ts == 15000
    assert cue.text == "心率过高，放慢"


def test_cue_minimal_fixture():
    cue = CoachCue.from_dict(load("coach_cue_v1_minimal.json"))
    assert cue.priority is CuePriority.MILESTONE
    assert cue.haptic is None and cue.text is None and cue.kind is None


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("coach_cue_*.json")), ids=lambda p: p.name)
def test_every_cue_fixture_round_trips(path: Path):
    data = json.loads(path.read_text())
    cue = CoachCue.from_dict(data)
    assert cue.to_dict() == data
    assert CoachCue.from_json(cue.to_json()) == cue


def test_cue_expiry():
    cue = CoachCue.from_dict(load("coach_cue_v1_minimal.json"))
    assert not cue.is_expired(cue.expires_at - 1)
    assert cue.is_expired(cue.expires_at)


def test_unknown_haptic_falls_back():
    cue = CoachCue.from_dict(load("coach_cue_v1_full.json") | {"haptic": "rumble"})
    assert cue.haptic is Haptic.NOTIFICATION


@pytest.mark.parametrize("patch", [{"v": 2}, {"priority": "urgent"}])
def test_rejects_bad_cues(patch: dict):
    with pytest.raises(ProtocolError):
        CoachCue.from_dict(load("coach_cue_v1_minimal.json") | patch)


def test_priority_rank_order():
    ranks = [p.rank for p in CuePriority]
    assert ranks == sorted(ranks, reverse=True)
    assert CuePriority.EMERGENCY.rank > CuePriority.COMPANION.rank
