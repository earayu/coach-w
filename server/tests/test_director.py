from dataclasses import replace

import pytest
from synth import Clock, Runner

from coachw.coach.director import GOAL_KEY, Director
from coachw.coach.metrics_state import MetricsState
from coachw.profiles.running import RUNNING
from coachw.protocol import CuePriority, Haptic, WorkoutState

# no companion chat unless a test asks for it
QUIET = replace(RUNNING, companion_topics=())


class Harness:
    def __init__(self, profile=QUIET, targets=None):
        self.clock = Clock()
        self.state = MetricsState(clock=self.clock, split_m=profile.split_m)
        self.director = Director(profile)
        self.targets = targets or {}
        self.kinds: list[str] = []
        self.events = []
        self.since_spoken = 0.0
        self.since_alert = 0.0
        self.run = Runner(self.state.update, self.clock, on_tick=self.tick)

    def tick(self):
        events = self.director.evaluate(
            self.state,
            self.targets,
            since_spoken_s=self.since_spoken,
            since_alert_s=self.since_alert,
        )
        self.events += events
        self.kinds += [e.kind for e in events]


def test_start_once_and_phase_change_after_warmup():
    h = Harness()
    h.run.run(30)
    assert h.kinds == ["start"]
    h.run.run(600)
    assert "phase:main" in h.kinds
    assert h.kinds.count("phase:main") == 1
    assert h.director.phase.name == "main"
    start = h.events[0]
    assert start.priority is CuePriority.MILESTONE and start.haptic is Haptic.START


def test_every_split_is_announced_with_its_numbers():
    h = Harness()
    h.run.run(700, speed=1000 / 300, hr=150)  # 2333 m
    splits = [e for e in h.events if e.kind.startswith("split:")]
    assert [e.kind for e in splits] == ["split:1", "split:2"]
    assert "第 1 公里" in splits[0].facts and "5 分" in splits[0].facts
    assert "平均心率 150" in splits[0].facts
    assert splits[0].watch_text == "第 1 公里"


def test_goal_milestones():
    h = Harness(targets={GOAL_KEY: 3000})
    h.run.run(1000, speed=3.2)  # 3200 m
    for kind in ("half", "last_split", "goal"):
        assert h.kinds.count(kind) == 1
    assert h.kinds.index("half") < h.kinds.index("last_split") < h.kinds.index("goal")
    assert "phase:cooldown" in h.kinds  # 90 % of the goal


def test_no_goal_milestones_without_goal():
    h = Harness()
    h.run.run(1000, speed=3.2)
    assert not {"half", "last_split", "goal", "phase:cooldown"} & set(h.kinds)


def test_end_is_announced_once():
    h = Harness()
    h.run.run(60)
    h.run.run(3, state=WorkoutState.ENDED)
    assert h.kinds.count("end") == 1
    end = next(e for e in h.events if e.kind == "end")
    assert "用时 1 分" in end.facts and end.haptic is Haptic.STOP


def test_paused_workout_has_no_milestones():
    h = Harness()
    h.run.run(10)
    h.run.run(700, state=WorkoutState.PAUSED)
    assert h.kinds == ["start"]


def test_data_lost_once_per_outage():
    h = Harness()
    h.run.run(60)
    h.clock.advance(31)
    h.tick()
    h.tick()
    assert h.kinds.count("data_lost") == 1
    h.run.run(5)
    h.clock.advance(31)
    h.tick()
    assert h.kinds.count("data_lost") == 2


def test_companion_after_interval_and_stretched_when_stable():
    h = Harness(profile=RUNNING)
    c = RUNNING.cadence
    h.since_alert = 0
    assert h.director.companion_interval_s(0) == c.companion_s
    assert h.director.companion_interval_s(c.stable_after_s) == pytest.approx(
        c.companion_s * c.stable_multiplier
    )
    h.run.run(20)
    h.since_spoken = c.companion_s - 1
    h.tick()
    assert "companion" not in h.kinds
    h.since_spoken = c.companion_s
    h.tick()
    assert h.kinds[-1] == "companion"
    assert h.events[-1].priority is CuePriority.COMPANION and h.events[-1].haptic is None
    h.since_alert = c.stable_after_s
    h.tick()
    assert h.kinds.count("companion") == 1


def test_no_start_announcement_when_joining_mid_workout():
    h = Harness()
    h.run.elapsed, h.run.distance = 900, 2500
    h.run.run(600, speed=1000 / 300)
    assert "start" not in h.kinds
    assert not any(k.startswith("phase:") for k in h.kinds)
    assert [k for k in h.kinds if k.startswith("split:")] == ["split:4"]


def test_companion_topic_moves_on_only_once_spoken():
    h = Harness(profile=RUNNING)
    h.run.run(20)
    h.since_spoken = RUNNING.cadence.companion_s
    h.tick()
    h.tick()  # offered again while the queue still holds it back
    first, again = (e.facts for e in h.events[-2:])
    assert first == again and RUNNING.companion_topics[0] in first
    h.director.companion_spoken()
    h.tick()
    assert RUNNING.companion_topics[1] in h.events[-1].facts
