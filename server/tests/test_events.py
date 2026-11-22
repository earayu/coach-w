from synth import Clock, Runner

from coachw.coach.events import (
    Alert,
    EventEngine,
    RuleContext,
    SplitTrend,
    Sustained,
    WindowVsBaseline,
    WindowVsTarget,
)
from coachw.coach.format import pace_seconds
from coachw.coach.metrics_state import MetricsState
from coachw.protocol import CuePriority, WorkoutState

ALERT = Alert(CuePriority.CORRECTION, 60, 20)

HR_HIGH = Sustained(
    kind="hr_high",
    field="hr_bpm",
    threshold="hr_max",
    for_s=20,
    alert=ALERT,
    facts=lambda v, t, s: f"{v:.0f}>{t:.0f} for {s:.0f}s",
)


def setup(**kwargs):
    clock = Clock()
    state = MetricsState(clock=clock, **kwargs)
    return state, Runner(state.update, clock), clock


def evaluate(rule, state, **targets):
    return EventEngine([rule]).evaluate(RuleContext(state, targets))


def test_sustained_needs_a_streak_not_a_spike():
    state, run, _ = setup()
    run.run(60, hr=150)
    run.run(10, hr=185)
    assert evaluate(HR_HIGH, state, hr_max=172) == []
    run.run(12, hr=185)
    [event] = evaluate(HR_HIGH, state, hr_max=172)
    assert event.kind == "hr_high"
    assert event.cooldown_key == "hr_high"
    assert event.facts.startswith("185>172")


def test_sustained_is_silent_without_target_or_sensor():
    state, run, _ = setup()
    run.run(60, hr=185)
    assert evaluate(HR_HIGH, state) == []
    state2, run2, _ = setup()
    run2.run(60, hr=None)
    assert evaluate(HR_HIGH, state2, hr_max=172) == []


def test_sustained_below():
    rule = Sustained("slow", "cadence_spm", 150, 20, ALERT, lambda v, t, s: "", above=False)
    state, run, _ = setup()
    run.run(30, cadence=140)
    assert len(evaluate(rule, state)) == 1


def test_engine_is_silent_on_stale_or_paused_data():
    state, run, clock = setup()
    run.run(60, hr=185)
    assert evaluate(HR_HIGH, state, hr_max=172)
    clock.advance(30)
    assert evaluate(HR_HIGH, state, hr_max=172) == []
    run.run(3, hr=185, state=WorkoutState.PAUSED)
    assert evaluate(HR_HIGH, state, hr_max=172) == []


def test_engine_respects_rule_start_time():
    rule = Sustained(
        "hr_high",
        "hr_bpm",
        172,
        20,
        Alert(CuePriority.CORRECTION, 60, 20, after_s=120),
        lambda v, t, s: "",
    )
    state, run, _ = setup()
    run.run(100, hr=185)
    assert evaluate(rule, state) == []
    run.run(30, hr=185)
    assert len(evaluate(rule, state)) == 1


GCT = WindowVsBaseline(
    kind="gct_rise",
    field="gct_ms",
    window_s=120,
    change=0.08,
    alert=ALERT,
    facts=lambda v, b, c: f"{v:.0f} vs {b:.0f} (+{c * 100:.0f}%)",
)


def test_window_vs_baseline_rise():
    state, run, _ = setup(baseline_s=(60, 300))
    run.run(400, gct=240)
    assert evaluate(GCT, state) == []
    run.run(120, gct=264)  # +10 %
    [event] = evaluate(GCT, state)
    assert event.facts == "264 vs 240 (+10%)"


def test_window_vs_baseline_needs_both_periods():
    state, run, _ = setup(baseline_s=(60, 300))
    run.run(200, gct=300)
    assert evaluate(GCT, state) == []
    state2, run2, _ = setup(baseline_s=(60, 300))
    run2.run(600, gct=None)
    assert evaluate(GCT, state2) == []


def test_window_vs_baseline_drop():
    rule = WindowVsBaseline("cadence_drop", "cadence_spm", 60, -0.05, ALERT, lambda v, b, c: "")
    state, run, _ = setup(baseline_s=(60, 300))
    run.run(400, cadence=176)
    assert evaluate(rule, state) == []
    run.run(60, cadence=164)  # -6.8 %
    assert len(evaluate(rule, state)) == 1


def pace_rule(direction):
    return WindowVsTarget(
        kind="pace",
        field="speed_mps",
        window_s=60,
        target="target_speed",
        tolerance=15,
        direction=direction,
        transform=pace_seconds,
        alert=ALERT,
        facts=lambda v, g, d: f"{v:.0f} {g:.0f} {d:+.0f}",
    )


def test_window_vs_target_pace():
    state, run, _ = setup()
    target = 1000 / 330  # 5'30"
    run.run(120, speed=1000 / 360)  # 6'00": 30 s slow
    [slow] = evaluate(pace_rule(+1), state, target_speed=target)
    assert slow.facts == "360 330 +30"
    assert evaluate(pace_rule(-1), state, target_speed=target) == []
    run.run(120, speed=1000 / 320)  # 10 s fast: inside tolerance
    assert evaluate(pace_rule(-1), state, target_speed=target) == []
    assert evaluate(pace_rule(+1), state) == []


def test_window_vs_target_ignores_standing_still():
    state, run, _ = setup()
    run.run(120, speed=0.0)
    assert evaluate(pace_rule(+1), state, target_speed=3.0) == []


DRIFT = SplitTrend(
    kind="pace_drift",
    metric=lambda s: s.duration_s,
    steps=2,
    min_step=10,
    direction=+1,
    alert=ALERT,
    facts=lambda values, splits: ",".join(f"{v:.0f}" for v in values),
)


def test_split_trend_fires_once_per_split():
    state, run, _ = setup()
    for pace in (300, 300):
        run.run(pace, speed=1000 / pace)
    run.run(320, speed=1000 / 320)
    assert evaluate(DRIFT, state) == []
    run.run(335, speed=1000 / 335)
    [event] = evaluate(DRIFT, state)
    assert event.facts == "300,320,335"
    assert event.cooldown_key == "pace_drift:4"


def test_split_trend_needs_every_step():
    state, run, _ = setup()
    for pace in (300, 330, 335, 336):
        run.run(pace, speed=1000 / pace)
    assert evaluate(DRIFT, state) == []
