"""Walking, hiking, cycling and fallback profiles driven end to end through CoachBrain (M4)."""

import json

import pytest
from test_brain import Session

from coachw.protocol import CuePriority, WorkoutState

ALERTS = (CuePriority.EMERGENCY, CuePriority.CORRECTION)


def alerts(s: Session) -> list[str]:
    return [d.cue.event.kind for d in s.deliveries if d.cue.priority in ALERTS]


def facts(s: Session, kind: str) -> str:
    return next(d.cue.event.facts for d in s.deliveries if d.cue.event.kind == kind)


@pytest.mark.parametrize(("activity", "label"), [("walking", "散步"), ("hiking", "徒步")])
def test_a_walk_is_company_not_coaching(activity, label):
    s = Session(activity=activity)
    s.run.run(40 * 60, speed=1.3, hr=110, cadence=110)  # ~3.1 km
    assert s.brain.profile.label == label
    kinds = s.kinds()
    assert kinds[0] == "start" and "陪着" in facts(s, "start")
    assert [k for k in kinds if k.startswith("split:")] == ["split:1", "split:2", "split:3"]
    assert "不用点评" in facts(s, "split:1")
    assert "companion" in kinds
    assert alerts(s) == []


def test_a_walk_still_watches_heart_rate():
    s = Session(activity="walking")
    s.run.run(120, speed=1.3, hr=110)
    s.run.run(40, speed=1.3, hr=188)
    assert alerts(s) == ["hr_emergency"]
    assert s.deliveries[-1].watch is not None


def test_a_walk_without_sensors_raises_nothing():
    s = Session(activity="hiking")
    s.run.run(30 * 60, speed=None, hr=None, cadence=None)
    assert alerts(s) == []


def test_cycling_speaks_km_per_hour_and_splits_every_5_km():
    s = Session(activity="cycling")
    s.run.run(30 * 60, speed=7.0, hr=140, cadence=None)  # 25.2 km/h, 12.6 km
    assert [k for k in s.kinds() if k.startswith("split:")] == ["split:1", "split:2"]
    assert "第 10 公里" in facts(s, "split:2") and "每小时" in facts(s, "split:2")
    m = s.brain.get_metrics()
    assert m["speed_kmh"] == 25.2
    assert "pace_per_km" not in m
    assert m["spoken"]["速度"] == "每小时 25 公里"


def test_cycling_without_cadence_or_power_sensors_never_mentions_them():
    s = Session(activity="cycling")
    s.run.run(40 * 60, speed=7.0, hr=140, cadence=None, power=None)
    assert alerts(s) == []
    assert "cadence_spm" not in s.brain.get_metrics()


def test_cycling_cadence_and_power_rules_with_sensors():
    s = Session(activity="cycling")
    s.run.run(16 * 60, speed=7.0, hr=140, cadence=90, power=200)
    assert alerts(s) == []
    s.run.run(4 * 60, speed=6.0, hr=140, cadence=72, power=150)
    assert set(alerts(s)) == {"cadence_drop", "power_drop"}


def test_cycling_heart_rate_emergency():
    s = Session(activity="cycling")
    s.run.run(120, speed=7.0, hr=140)
    s.run.run(30, speed=7.0, hr=190)
    assert alerts(s) == ["hr_emergency"]
    assert "停下来" in facts(s, "hr_emergency")


def test_fallback_marks_time_and_energy_without_distance():
    s = Session(activity="yoga")
    s.run.run(25 * 60, speed=None, hr=120, cadence=None, kcal_per_s=0.1)
    kinds = s.kinds()
    assert s.brain.profile.name == "fallback"
    assert [k for k in kinds if k.startswith("time:")] == ["time:1", "time:2"]
    assert "20 分钟" in facts(s, "time:2") and "120 千卡" in facts(s, "time:2")
    assert not [k for k in kinds if k.startswith("split:")]
    assert alerts(s) == []
    assert s.brain.get_metrics()["spoken"]["能量"] == "150 千卡"


def test_fallback_without_heart_rate_raises_nothing():
    s = Session(activity="other")
    s.run.run(30 * 60, speed=None, hr=None, cadence=None)
    assert alerts(s) == []


def test_fallback_heart_rate_emergency():
    s = Session(activity="other")
    s.run.run(60, speed=None, hr=120)
    s.run.run(30, speed=None, hr=190)
    assert alerts(s) == ["hr_emergency"]


def test_end_of_run_is_one_sentence_summary_with_whole_workout_numbers():
    s = Session()
    s.run.run(12 * 60, speed=1000 / 330, hr=150, kcal_per_s=0.2)
    # the watch keeps sending its last readings in the final frame
    s.run.run(3, state=WorkoutState.ENDED, kcal_per_s=0)
    text = facts(s, "end")
    assert text.startswith("跑步结束了")
    assert "平均心率150" in text and "平均配速每公里 5 分 30 秒" in text
    assert "消耗 144 千卡" in text and "最快的是第" in text
    assert "一句话总结" in text


def test_end_of_ride_reads_speed():
    s = Session(activity="cycling")
    s.run.run(11 * 60, speed=7.0, hr=140)
    s.run.run(15, state=WorkoutState.ENDED)
    assert "平均速度每小时 25 公里" in facts(s, "end")


def test_gps_coordinates_never_reach_the_model():
    s = Session(activity="hiking")
    s.run.run(60, speed=1.2, hr=110)
    s.run.send(speed_mps=1.2, hr_bpm=110, lat=39.9042, lon=116.4074, alt_m=845.0)
    results = [
        s.brain.get_metrics(),
        s.brain.get_progress(),
        s.brain.end_workout_summary(),
        {"status": s.brain.status_summary()},
    ]
    text = json.dumps(results, ensure_ascii=False)
    assert "39.9" not in text and "116.4" not in text
    assert "lat" not in results[0] and "lon" not in results[0]
    assert results[0]["spoken"]["海拔"] == "845 米"
