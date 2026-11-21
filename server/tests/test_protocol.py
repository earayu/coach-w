import json
from pathlib import Path

import pytest

from coachw.protocol import MetricsFrame, ProtocolError, WorkoutState

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


@pytest.mark.parametrize("path", sorted(FIXTURES.glob("*.json")), ids=lambda p: p.name)
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
