import re
from pathlib import Path

import pytest

from coachw.coach.events import SplitTrend, Sustained, WindowVsBaseline, WindowVsTarget
from coachw.profiles.fallback import FALLBACK
from coachw.profiles.registry import PROFILES, profile_for
from coachw.profiles.running import RUNNING
from coachw.protocol import CuePriority

COACH_DIR = Path(__file__).resolve().parents[1] / "src" / "coachw" / "coach"
ACTIVITY_NAMES = ("running", "walking", "hiking", "cycling", "swimming", "yoga")


def test_registry_maps_activities():
    assert profile_for("running") is RUNNING
    other = profile_for("cycling")
    assert other.name == FALLBACK.name and other.activity_types == ("cycling",)


def test_activities_are_claimed_once():
    claimed = [a for p in PROFILES for a in p.activity_types]
    assert len(claimed) == len(set(claimed))


@pytest.mark.parametrize("path", sorted(COACH_DIR.glob("*.py")), ids=lambda p: p.name)
def test_kernel_has_no_activity_branches(path: Path):
    """AGENTS.md: activity differences live only in profiles."""
    source = path.read_text()
    for name in ACTIVITY_NAMES:
        assert not re.search(rf"[\"']{name}[\"']", source), f"{path.name} mentions {name!r}"
    assert "profiles.running" not in source and "profiles.fallback" not in source


def test_running_profile_covers_the_p0_rules():
    rules = {r.kind: r for r in RUNNING.rules}
    assert isinstance(rules["hr_emergency"], Sustained)
    assert rules["hr_emergency"].alert.priority is CuePriority.EMERGENCY
    assert isinstance(rules["hr_ceiling"], Sustained)
    assert isinstance(rules["pace_slow"], WindowVsTarget)
    assert isinstance(rules["pace_fast"], WindowVsTarget)
    assert isinstance(rules["pace_drift"], SplitTrend)
    assert isinstance(rules["cadence_drop"], WindowVsBaseline)
    assert isinstance(rules["gct_rise"], WindowVsBaseline)
    assert rules["hr_emergency"].alert.key == rules["hr_ceiling"].alert.key


def test_running_profile_shape():
    assert RUNNING.split_m == 1000
    assert [p.name for p in RUNNING.phases] == ["warmup", "main", "cooldown"]
    assert [t.name for t in RUNNING.tools] == ["adjust_target_pace"]
    assert "adjust_target_pace" in RUNNING.prompt
    assert RUNNING.cadence.max_per_minute >= 1
    readings = {m.field: m.read for m in RUNNING.metrics}
    assert readings["speed_mps"](1000 / 330) == "每公里 5 分 30 秒"
    assert readings["speed_mps"](0.0) is None
