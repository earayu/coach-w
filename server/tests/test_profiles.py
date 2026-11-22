import re
from pathlib import Path

import pytest

from coachw.coach.events import SplitTrend, Sustained, WindowVsBaseline, WindowVsTarget
from coachw.profiles.base import Mode
from coachw.profiles.cycling import CYCLING
from coachw.profiles.fallback import FALLBACK
from coachw.profiles.registry import PROFILES, profile_for
from coachw.profiles.running import RUNNING
from coachw.profiles.walking import HIKING, WALKING
from coachw.protocol import CuePriority

COACH_DIR = Path(__file__).resolve().parents[1] / "src" / "coachw" / "coach"
ACTIVITY_NAMES = ("running", "walking", "hiking", "cycling", "swimming", "yoga")


def test_registry_maps_activities():
    assert profile_for("running") is RUNNING
    assert profile_for("walking") is WALKING
    assert profile_for("hiking") is HIKING
    assert profile_for("cycling") is CYCLING
    for activity in ("other", "yoga", "swimming"):
        other = profile_for(activity)
        assert other.name == FALLBACK.name and other.activity_types == (activity,)


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


def test_walking_and_hiking_are_companions_that_only_watch_safety():
    for profile in (WALKING, HIKING):
        assert profile.mode is Mode.COMPANION
        assert [r.kind for r in profile.rules] == ["hr_emergency"]
        assert profile.split_m == 1000 and profile.tools == ()
        assert profile.speed_as_pace
    assert WALKING.label == "散步" and HIKING.label == "徒步"
    assert "海拔" in HIKING.prompt


def test_cycling_reads_speed_as_km_per_hour():
    assert CYCLING.mode is Mode.COACH
    assert not CYCLING.speed_as_pace
    readings = {m.field: m.read for m in CYCLING.metrics}
    assert readings["speed_mps"](25 / 3.6) == "每小时 25 公里"
    assert readings["speed_mps"](0.0) is None
    assert readings["cadence_spm"](85) == "每分钟 85 转"
    assert "配速" not in [m.label for m in CYCLING.metrics]
    assert CYCLING.cadence.max_per_minute <= 2
    rules = {r.kind: r for r in CYCLING.rules}
    assert rules["cadence_drop"].field == "cadence_spm" and rules["power_drop"].field == "power_w"


def test_fallback_needs_only_heart_rate_time_and_energy():
    assert FALLBACK.mode is Mode.COMPANION
    assert FALLBACK.split_m is None and FALLBACK.time_mark_s
    assert {m.field for m in FALLBACK.metrics} == {"hr_bpm", "energy_kcal"}
    assert {r.field for r in FALLBACK.rules} == {"hr_bpm"}
    assert "千卡" in FALLBACK.time_mark_facts(1200, 150) and "20" in FALLBACK.time_mark_facts(
        1200, None
    )
