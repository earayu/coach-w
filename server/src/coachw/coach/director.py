"""Director: the timeline of one workout (spec 4.3).

Phases and splits come from the profile; milestones (start, each split, half way, last split,
goal reached, end) and companion chat between them are generic. Every milestone fires once.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field

from coachw.coach.events import CoachEvent
from coachw.coach.format import say_distance, say_duration
from coachw.coach.metrics_state import MetricsState
from coachw.profiles.base import ActivityProfile, Phase
from coachw.protocol import CuePriority, Haptic, WorkoutState

GOAL_KEY = "goal_distance_m"

# Tell the athlete once when the watch has gone quiet this long during a running workout.
DATA_LOST_AFTER_S = 30.0

MILESTONE_TTL_S = 20.0
COMPANION_TTL_S = 30.0


def _milestone(
    kind: str, facts: str, haptic: Haptic | None = None, text: str | None = None
) -> CoachEvent:
    return CoachEvent(
        kind=kind,
        priority=CuePriority.MILESTONE,
        facts=facts,
        cooldown_key=kind,
        cooldown_s=0.0,
        ttl_s=MILESTONE_TTL_S,
        haptic=haptic,
        watch_text=text,
    )


@dataclass(slots=True)
class Director:
    profile: ActivityProfile
    _fired: set[str] = field(default_factory=set)
    _phase: Phase | None = None
    _splits_seen: int = 0
    _marks_seen: int | None = None
    _topic: int = 0

    @property
    def phase(self) -> Phase | None:
        return self._phase

    def current_phase(self, state: MetricsState, targets: Mapping[str, float]) -> Phase | None:
        if not state.started:
            return None
        goal = targets.get(GOAL_KEY)
        distance = state.distance_m
        current = None
        for phase in self.profile.phases:
            by_time = phase.after_s is not None and state.elapsed_s >= phase.after_s
            by_goal = (
                phase.goal_fraction is not None
                and goal
                and distance is not None
                and distance >= goal * phase.goal_fraction
            )
            if by_time or by_goal:
                current = phase
        return current

    def evaluate(
        self,
        state: MetricsState,
        targets: Mapping[str, float],
        *,
        since_spoken_s: float,
        since_alert_s: float,
    ) -> list[CoachEvent]:
        frame = state.latest
        if frame is None:
            return []
        if frame.state is WorkoutState.ENDED:
            return self._once("end", self._end_facts(state), Haptic.STOP, "运动结束")
        if state.is_stale():
            # a paused watch sends no heartbeat: only a running workout going quiet is a lost link
            if state.started and state.is_running and (state.age_s() or 0) >= DATA_LOST_AFTER_S:
                return self._once(
                    "data_lost",
                    "已经有一会儿收不到手表的数据了。提醒用户看一下手表上的运动是否还在进行，"
                    "并说明现在暂时报不了实时数据。",
                )
            return []
        self._fired.discard("data_lost")
        if not state.is_running:
            return []

        events: list[CoachEvent] = []
        if state.joined_at_start:
            events += self._once("start", self._start_facts(targets), Haptic.START, "开始")
        events += self._phase_events(state, targets)
        events += self._split_events(state)
        events += self._time_mark_events(state)
        events += self._goal_events(state, targets)
        if not events:
            events += self._companion(state, since_spoken_s, since_alert_s)
        return events

    # -- milestones ----------------------------------------------------------------------------

    def _once(
        self, kind: str, facts: str, haptic: Haptic | None = None, text: str | None = None
    ) -> list[CoachEvent]:
        if kind in self._fired:
            return []
        self._fired.add(kind)
        return [_milestone(kind, facts, haptic, text)]

    def _start_facts(self, targets: Mapping[str, float]) -> str:
        goals = self.profile.describe_targets(targets)
        goal_text = f"今天的目标：{'，'.join(goals)}。" if goals else ""
        return f"{self.profile.label}刚刚开始。{goal_text}{self.profile.start_hint}"

    def _phase_events(self, state: MetricsState, targets: Mapping[str, float]) -> list[CoachEvent]:
        phase = self.current_phase(state, targets)
        previous, self._phase = self._phase, phase
        if phase is None or phase == previous or previous is None:
            return []
        return self._once(
            f"phase:{phase.name}",
            f"进入{phase.label}阶段（用时 {say_duration(state.elapsed_s)}）。"
            f"用一句话告诉用户现在进入{phase.label}，以及这个阶段该怎么做。",
            Haptic.NOTIFICATION,
            phase.label,
        )

    def _split_events(self, state: MetricsState) -> list[CoachEvent]:
        splits = state.splits
        if len(splits) <= self._splits_seen:
            return []
        self._splits_seen = len(splits)
        last = splits[-1]
        return self._once(
            f"split:{last.index}",
            self.profile.split_facts(last),
            Haptic.SUCCESS,
            f"第 {last.index} {self.profile.split_label}",
        )

    def _time_mark_events(self, state: MetricsState) -> list[CoachEvent]:
        mark = self.profile.time_mark_s
        if not mark:
            return []
        if self._marks_seen is None:
            # marks before this session first saw the workout are not announced late
            self._marks_seen = int((state.first_elapsed_s or 0.0) // mark)
        n = int(state.elapsed_s // mark)
        if n <= self._marks_seen:
            return []
        self._marks_seen = n
        energy = state.latest.energy_kcal if state.latest else None
        return self._once(
            f"time:{n}",
            self.profile.time_mark_facts(n * mark, energy),
            Haptic.SUCCESS,
            f"{n * mark / 60:.0f} 分钟",
        )

    def resume(self, state: MetricsState, elapsed_s: float) -> None:
        """The workout was already under way in an earlier session: what that session announced
        (start, splits, time marks so far) is not announced again."""
        self._fired.add("start")
        self._fired |= {f"split:{s.index}" for s in state.splits}
        self._splits_seen = len(state.splits)
        if mark := self.profile.time_mark_s:
            self._marks_seen = int(elapsed_s // mark)

    def _goal_events(self, state: MetricsState, targets: Mapping[str, float]) -> list[CoachEvent]:
        goal, distance, split = targets.get(GOAL_KEY), state.distance_m, self.profile.split_m
        if not goal or distance is None:
            return []
        events: list[CoachEvent] = []
        if distance >= goal:
            events += self._once(
                "goal",
                f"已经完成今天的目标距离 {say_distance(goal)}，"
                f"用时 {say_duration(state.elapsed_s)}。祝贺用户，并建议慢下来放松。",
                Haptic.SUCCESS,
                "完成目标",
            )
        elif split and goal > split and goal - distance <= split:
            events += self._once(
                "last_split",
                f"进入最后一{self.profile.split_label}，还剩 {say_distance(goal - distance)}。"
                "给用户鼓劲。",
                Haptic.DIRECTION_UP,
                f"最后一{self.profile.split_label}",
            )
        elif distance >= goal / 2:
            events += self._once(
                "half",
                f"目标完成一半：已完成 {say_distance(distance)}，"
                f"用时 {say_duration(state.elapsed_s)}。"
                "简短鼓励。",
                Haptic.NOTIFICATION,
                "半程",
            )
        return events

    def _end_facts(self, state: MetricsState) -> str:
        """The one-sentence summary at the end (spec 2 step 6), from whole-workout numbers."""
        parts = [f"用时 {say_duration(state.elapsed_s)}"]
        if distance := state.distance_m:
            parts.append(f"距离 {say_distance(distance)}")
        # the profile lists its metrics most important first
        for spec in self.profile.metrics[:2]:
            mean = state.session_mean(spec.field)
            if mean is not None and (spoken := spec.read(mean)):
                parts.append(f"平均{spec.label}{spoken}")
        energy = state.latest.energy_kcal if state.latest else None
        if energy:
            parts.append(f"消耗 {energy:.0f} 千卡")
        splits = state.splits
        if len(splits) >= 2:
            best = min(splits, key=lambda s: s.duration_s)
            parts.append(
                f"最快的是第 {best.index} {self.profile.split_label}"
                f"（{say_duration(best.duration_s)}）"
            )
        return f"{self.profile.label}结束了：{'，'.join(parts)}。{self.profile.end_hint}"

    # -- companion -----------------------------------------------------------------------------

    def companion_spoken(self) -> None:
        """The companion cue was released: the next one takes the next topic. Offers the queue
        held back or dropped (user speaking, expired) do not use a topic up."""
        self._topic += 1

    def companion_interval_s(self, since_alert_s: float) -> float:
        c = self.profile.cadence
        stable = since_alert_s >= c.stable_after_s
        return c.companion_s * (c.stable_multiplier if stable else 1.0)

    def _companion(
        self, state: MetricsState, since_spoken_s: float, since_alert_s: float
    ) -> list[CoachEvent]:
        topics = self.profile.companion_topics
        if not topics or since_spoken_s < self.companion_interval_s(since_alert_s):
            return []
        topic = topics[self._topic % len(topics)]
        return [
            CoachEvent(
                kind="companion",
                priority=CuePriority.COMPANION,
                facts=f"已经用时 {say_duration(state.elapsed_s)}。{topic}",
                cooldown_key="companion",
                cooldown_s=self.profile.cadence.companion_s / 2,
                ttl_s=COMPANION_TTL_S,
            )
        ]
