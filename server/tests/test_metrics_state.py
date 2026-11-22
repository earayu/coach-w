import pytest
from synth import Clock, Runner, frame

from coachw.coach.metrics_state import MetricsState
from coachw.protocol import WorkoutState


def setup(**kwargs):
    clock = Clock()
    state = MetricsState(clock=clock, **kwargs)
    return state, Runner(state.update, clock), clock


def test_window_mean_over_recent_running_time():
    state, run, _ = setup()
    run.run(60, hr=140)
    run.run(10, hr=160)
    w10 = state.window("hr_bpm", 10)
    assert w10.mean == pytest.approx(160)
    w30 = state.window("hr_bpm", 30)
    assert w30.mean == pytest.approx((20 * 140 + 10 * 160) / 30, abs=1)
    assert w30.min == 140 and w30.max == 160


def test_window_needs_enough_coverage():
    state, run, _ = setup()
    run.run(5)
    assert state.window("hr_bpm", 30) is None
    assert state.window("hr_bpm", 5) is not None


def test_missing_sensor_has_no_window():
    state, run, _ = setup()
    run.run(120, hr=None)
    assert state.window("hr_bpm", 30) is None
    assert state.streak_s("hr_bpm", lambda v: True) == 0
    assert state.session_mean("hr_bpm") is None


def test_streak_breaks_on_gap_and_on_dip():
    state, run, _ = setup()
    run.run(20, hr=180)
    assert state.streak_s("hr_bpm", lambda v: v > 170) == pytest.approx(19)
    run.run(1, hr=160)
    run.run(5, hr=180)
    assert state.streak_s("hr_bpm", lambda v: v > 170) == pytest.approx(4)
    run.run(1, hr=None)
    assert state.streak_s("hr_bpm", lambda v: v > 170) == 0


def test_splits_interpolate_the_crossing():
    state, run, _ = setup()
    run.run(300, speed=4.0, hr=150)  # 1200 m
    [split] = state.splits
    assert split.index == 1
    assert split.duration_s == pytest.approx(250, abs=0.01)
    assert split.means["hr_bpm"] == pytest.approx(150)
    run.run(300, speed=3.0)  # 900 m more → 2100 m
    assert [s.index for s in state.splits] == [1, 2]
    assert state.splits[1].duration_s == pytest.approx(200 / 4 + 800 / 3, abs=0.5)


def test_batch_crossing_several_splits_at_once():
    state, _, clock = setup()
    state.update(frame(1, 10, distance_m=10))
    state.update(frame(2, 610, distance_m=2010))
    assert [s.index for s in state.splits] == [1, 2]
    assert state.splits[0].elapsed_s == pytest.approx(10 + 600 * 990 / 2000)


def test_no_splits_without_distance_or_split_length():
    state, run, _ = setup(split_m=None)
    run.run(600, speed=4.0)
    assert state.splits == []


def test_baseline_only_after_its_period():
    state, run, _ = setup(baseline_s=(60, 120))
    run.run(119, gct=240)
    assert state.baseline("gct_ms") is None
    run.run(60, gct=300)
    assert state.baseline("gct_ms") == pytest.approx(240)


def test_paused_frames_update_latest_but_not_windows():
    state, run, _ = setup()
    run.run(30, hr=150)
    run.run(30, hr=100, state=WorkoutState.PAUSED)
    assert state.latest.state is WorkoutState.PAUSED
    assert not state.is_running
    assert state.window("hr_bpm", 30).mean == pytest.approx(150)


def test_late_frames_never_overwrite_newer():
    state, _, _ = setup()
    assert state.update(frame(10, 20, hr_bpm=150))
    assert not state.update(frame(9, 19, hr_bpm=99))
    assert state.latest.hr_bpm == 150


def test_stale_after_silence():
    state, run, clock = setup()
    assert state.is_stale()
    run.run(5)
    assert not state.is_stale()
    clock.advance(11)
    assert state.is_stale()
    assert state.snapshot()["available"] is False


def test_history_is_bounded():
    state, run, _ = setup(history_s=60)
    run.run(600)
    assert len(state._samples) <= 62


def test_never_keeps_coordinates():
    state, _, _ = setup()
    state.update(frame(1, 1, lat=39.9, lon=116.4, hr_bpm=140))
    assert all("lat" not in s.values and "lon" not in s.values for s in state._samples)


def test_joining_mid_workout_skips_unseen_and_partial_splits():
    state, _, _ = setup()
    state.update(frame(1, 600, distance_m=2400))
    for i in range(2, 800):
        state.update(frame(i, 600 + i, distance_m=2400 + 3.0 * i))
    # 3000 m was the first boundary seen: the split before it is partial, so not timed
    assert [s.index for s in state.splits] == [4]
    assert state.splits[0].duration_s == pytest.approx(1000 / 3, abs=1)
    assert not state.joined_at_start


def test_joined_at_start():
    state, run, _ = setup()
    run.run(5)
    assert state.joined_at_start and state.first_elapsed_s == 1


def test_a_long_pause_still_reports_totals_but_no_old_live_readings():
    state, run, clock = setup()
    run.run(100, hr=150)
    run.run(1, state=WorkoutState.PAUSED, hr=150)
    clock.advance(120)  # the watch sends no heartbeat while paused
    snap = state.snapshot()
    assert snap["available"] is True and snap["live_readings"] is False
    assert snap["state"] == "paused" and snap["elapsed_s"] == 100
    assert snap["distance_m"] == pytest.approx(300)
    assert "hr_bpm" not in snap and "pace_per_km" not in snap
