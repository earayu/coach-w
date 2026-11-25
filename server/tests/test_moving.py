"""When the athlete really started, and the slope they are on (COCH-22)."""

from synth import frame
from test_brain import Session

from coachw.coach.brain import describe_climb
from coachw.coach.metrics_state import MetricsState
from coachw.profiles.running import RUNNING


def test_a_drive_before_the_run_is_not_the_run():
    s = Session()
    # six minutes in a car: 17 m/s at a wrist's idle cadence
    s.run.run(360, speed=17.0, cadence=40, hr=70)
    assert "start" not in s.kinds()
    status = s.brain.status_summary()
    assert "还没看到用户在跑步" in status
    s.run.run(120, speed=2.8, cadence=170, hr=140)
    assert s.kinds()[0] == "start"
    assert not [k for k in s.kinds() if k.startswith("split:")]  # none from the car either
    start = s.deliveries[0].instructions
    assert "手表已经计时 6 分" in start and "现在才真正开始跑步" in start
    assert s.brain.state.moving_since_s == 361
    assert "实际跑步了约 1 分" in s.brain.status_summary()
    progress = s.brain.get_progress()
    assert progress["moving_since_elapsed_s"] == 361 and progress["active_s"] == 119


def test_warm_up_counts_from_the_real_start():
    s = Session()
    s.run.run(400, speed=17.0, cadence=40)
    s.run.run(400, speed=2.8, cadence=170)
    # 800 s on the watch, but only 400 s running: still warming up
    assert s.brain.phase_label() == "热身"
    s.run.run(250, speed=2.8, cadence=170)
    assert s.brain.phase_label() == "主训练"


def test_an_ordinary_start_is_unchanged():
    s = Session()
    s.run.run(5)
    assert s.kinds()[0] == "start"
    assert "现在才真正开始" not in s.deliveries[0].instructions
    assert "真正开始" not in s.brain.status_summary()


def climbing_state(rise_per_s: float, seconds: int = 90) -> MetricsState:
    state = MetricsState(moving=RUNNING.moving)
    for i in range(1, seconds + 1):
        state.update(
            frame(
                i,
                float(i),
                distance_m=3.0 * i,
                alt_m=10 + rise_per_s * i,
                speed_mps=3.0,
                cadence_spm=170,
            )
        )
    return state


def test_climb_over_the_last_minute():
    climb = climbing_state(0.15).climb(60)
    assert climb is not None
    assert abs(climb.grade - 0.05) < 0.005 and abs(climb.alt_change_m - 8) < 1
    assert "上坡" in describe_climb(climb) and "坡度约 5%" in describe_climb(climb)
    down = climbing_state(-0.15).climb(60)
    assert "下坡" in describe_climb(down)
    assert describe_climb(climbing_state(0.0).climb(60)) is None
    assert MetricsState().climb(60) is None


def test_an_uphill_explains_the_heart_rate():
    s = Session()
    for i in range(1, 400):
        s.clock.advance(1)
        s.brain.on_frame(
            frame(
                i,
                float(i),
                distance_m=3.0 * i,
                alt_m=10 + (0.15 * (i - 300) if i > 300 else 0),
                speed_mps=3.0,
                cadence_spm=170,
                hr_bpm=150,
            )
        )
        s.tick()
    assert "uphill" in s.kinds()
    uphill = next(d for d in s.deliveries if d.cue.event.kind == "uphill")
    assert "上坡心率升高、配速变慢是正常的" in uphill.instructions
    assert "地形：最近一分钟在上坡" in s.brain.status_summary()
    metrics = s.brain.get_metrics()
    assert metrics["grade_pct"] > 3 and metrics["alt_change_1min_m"] > 3
