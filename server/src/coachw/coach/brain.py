"""CoachBrain: one athlete's coaching state for one session.

Wires MetricsState → Director + EventEngine → CueQueue for the profile matching the workout's
`activity`, and answers the coach tools. No LiveKit here: the agent module feeds frames in, asks
`tick()` once a second what to say, and turns a release into speech and a watch cue.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import Any

from coachw.coach.cue_queue import Cue, CueQueue, Release
from coachw.coach.director import GOAL_KEY, Director
from coachw.coach.events import EventEngine, RuleContext
from coachw.coach.format import say_distance, say_duration, speed_kmh
from coachw.coach.metrics_state import MetricsState
from coachw.profiles.base import ActivityProfile, Athlete
from coachw.profiles.registry import profile_for
from coachw.protocol import (
    PROTOCOL_VERSION,
    CoachCue,
    CoachResume,
    CuePriority,
    MetricsFrame,
    WorkoutState,
)

QUIET_MAX_MIN = 30

# Cues the watch also buzzes for. Companion chat stays in the ear only.
WATCH_PRIORITIES = (CuePriority.EMERGENCY, CuePriority.CORRECTION, CuePriority.MILESTONE)

PRIORITY_TONE = {
    CuePriority.EMERGENCY: "这是安全提醒，语气坚定、立刻说，一句话",
    CuePriority.CORRECTION: "这是纠正提醒，语气友好但明确，一句话",
    CuePriority.MILESTONE: "这是节点播报，简短有力，一两句话",
    CuePriority.COMPANION: "这是陪伴闲聊，轻松自然，一句话，可以问用户一个简单问题",
}


@dataclass(frozen=True, slots=True)
class Delivery:
    """What the agent should do with a released cue."""

    cue: Cue
    instructions: str
    interrupt: bool
    watch: CoachCue | None


def cue_instructions(cue: Cue) -> str:
    return (
        f"【教练提示】{cue.event.facts}\n"
        f"{PRIORITY_TONE[cue.priority]}。用自然的中文口语对用户说出来，"
        "只使用这里给出的数字，不要补充其他数字，不要提到这是系统提示。"
    )


class CoachBrain:
    def __init__(
        self,
        athlete: Athlete,
        *,
        profiles: Callable[[str], ActivityProfile] = profile_for,
        clock: Callable[[], float] = time.monotonic,
        wall_ms: Callable[[], int] = lambda: int(time.time() * 1000),
    ) -> None:
        self.athlete = athlete
        self._profiles = profiles
        self._clock = clock
        self._wall_ms = wall_ms
        self.profile: ActivityProfile | None = None
        self.targets: dict[str, float] = {}
        self.state = MetricsState(clock=clock)
        self.director: Director | None = None
        self.engine: EventEngine | None = None
        self.queue = CueQueue(max_per_minute=3, min_gap_s=10)
        self.started_at = clock()
        self.last_talk_at: float | None = None
        self.alerts: dict[str, int] = {}
        self.profile_version = 0
        self.resumed: CoachResume | None = None

    # -- input ---------------------------------------------------------------------------------

    def on_frame(self, frame: MetricsFrame) -> bool:
        if self.profile is None or frame.activity not in self.profile.activity_types:
            if self.state.latest and (frame.ts, frame.seq) <= (
                self.state.latest.ts,
                self.state.latest.seq,
            ):
                return False
            self._load(self._profiles(frame.activity))
        return self.state.update(frame)

    def _load(self, profile: ActivityProfile) -> None:
        """A new activity starts a fresh coaching state; quiet mode carries over."""
        quiet_until = self.queue.quiet_until
        self.profile = profile
        self.targets = profile.default_targets(self.athlete)
        self.state = MetricsState(
            split_m=profile.split_m, baseline_s=profile.baseline_s, clock=self._clock
        )
        self.director = Director(profile)
        self.engine = EventEngine(profile.rules)
        c = profile.cadence
        self.queue = CueQueue(max_per_minute=c.max_per_minute, min_gap_s=c.min_gap_s)
        self.queue.quiet_until = quiet_until
        self.alerts = {}
        self.profile_version += 1

    def resume(self, resume: CoachResume) -> bool:
        """Carry on a workout an earlier session coached (spec 7.4). Returns whether it applied."""
        if self.resumed is not None:
            return False
        if self.profile is None or resume.activity not in self.profile.activity_types:
            if self.state.latest is not None:
                # this session already follows another activity first-hand
                return False
            self._load(self._profiles(resume.activity))
        if self.director is None:
            return False
        self.state.seed(
            elapsed_s=resume.elapsed_s,
            distance_m=resume.distance_m,
            km_marks_s=resume.km_marks_s,
            means=resume.means,
            samples=resume.samples or 1,
        )
        self.director.resume(self.state, resume.elapsed_s)
        self.resumed = resume
        return True

    def resume_greeting(self) -> str | None:
        """Instead of the first-time greeting when the session joined a workout under way."""
        resume = self.resumed
        if resume is None or self.profile is None:
            return None
        parts = [f"已经用时 {say_duration(resume.elapsed_s)}"]
        if resume.distance_m:
            parts.append(f"完成 {say_distance(resume.distance_m)}")
        state = "暂停中" if resume.state is WorkoutState.PAUSED else "进行中"
        return (
            f"【教练提示】语音刚刚连上，用户的{self.profile.label}{state}，{'，'.join(parts)}，"
            "手表上的记录没有中断。用一句简短的话告诉用户你在线了、会继续陪着他，"
            "可以带上这里的用时和距离，不要重新做自我介绍，不要补充其他数字。"
        )

    # -- timing --------------------------------------------------------------------------------

    def tick(self, *, user_speaking: bool, agent_speaking: bool) -> Delivery | None:
        """Evaluate the timeline and rules, then release at most one cue."""
        if self.profile is None or self.director is None or self.engine is None:
            return None
        now = self._clock()
        if user_speaking or agent_speaking:
            # a conversation counts as talk: companion chat waits its interval after it too
            self.last_talk_at = now
        ctx = RuleContext(self.state, self.targets)
        since_spoken = now - max(
            self.queue.last_spoken_at or self.started_at, self.last_talk_at or self.started_at
        )
        since_alert = now - (self.queue.last_alert_at or self.started_at)
        events = self.engine.evaluate(ctx) + self.director.evaluate(
            self.state, self.targets, since_spoken_s=since_spoken, since_alert_s=since_alert
        )
        for event in events:
            self.queue.offer(event, now)
        release = self.queue.next(now, user_speaking=user_speaking, agent_speaking=agent_speaking)
        if release is None:
            return None
        if release.cue.priority is CuePriority.COMPANION:
            self.director.companion_spoken()
        return self._deliver(release)

    def _deliver(self, release: Release) -> Delivery:
        cue = release.cue
        if cue.priority in (CuePriority.EMERGENCY, CuePriority.CORRECTION):
            self.alerts[cue.event.kind] = self.alerts.get(cue.event.kind, 0) + 1
        watch = None
        if cue.priority in WATCH_PRIORITIES and cue.event.haptic is not None:
            now_ms = self._wall_ms()
            watch = CoachCue(
                v=PROTOCOL_VERSION,
                id=cue.id,
                ts=now_ms,
                expires_at=now_ms + int((cue.expires_at - self._clock()) * 1000),
                priority=cue.priority,
                kind=cue.event.kind,
                haptic=cue.event.haptic,
                text=cue.event.watch_text,
            )
        return Delivery(cue, cue_instructions(cue), release.interrupt, watch)

    # -- summaries and tools -------------------------------------------------------------------

    def phase_label(self) -> str:
        if self.director is None:
            return "未开始"
        if self.state.latest and self.state.latest.state is WorkoutState.ENDED:
            return "结束"
        phase = self.director.current_phase(self.state, self.targets)
        return phase.label if phase else "准备"

    def status_summary(self) -> str | None:
        """Context for the model, injected without a reply. Deliberately free of fast-changing
        numbers (heart rate, pace): the model must call get_metrics for those (spec 4.2, 14.2)."""
        if self.profile is None or self.state.latest is None:
            return None
        parts = [f"运动：{self.profile.label}", f"阶段：{self.phase_label()}"]
        parts.append(f"workout 状态：{self.state.latest.state}")
        if self.state.started:
            parts.append(f"已用时约 {say_duration(self.state.elapsed_s)}")
        if (d := self.state.distance_m) is not None:
            parts.append(f"已完成约 {say_distance(d)}")
        if self.state.splits:
            parts.append(f"已完成第 {self.state.splits[-1].index} {self.profile.split_label}")
        if goals := self.profile.describe_targets(self.targets):
            parts.append(f"目标：{'，'.join(goals)}")
        if self.state.is_stale():
            parts.append("手表数据暂时中断")
        now = self._clock()
        if self.queue.is_quiet(now):
            parts.append(f"用户要求安静，还剩约 {say_duration(self.queue.quiet_remaining_s(now))}")
        return (
            "【运动状态，仅供参考，不要回复】"
            + "；".join(parts)
            + "。用户问到具体数据时仍然必须先调用 get_metrics 或 get_progress。"
        )

    def get_metrics(self) -> dict[str, Any]:
        out = self.state.snapshot()
        if not out["available"] or self.profile is None:
            return out
        if not self.profile.speed_as_pace:
            out.pop("pace_per_km", None)
            if (speed := out.get("speed_mps")) is not None:
                out["speed_kmh"] = round(speed_kmh(speed), 1)
        # how the profile says each metric, so the model reads e.g. km/h on a bike
        spoken = {
            spec.label: text
            for spec in self.profile.metrics
            if (value := out.get(spec.field)) is not None and (text := spec.read(value))
        }
        if spoken:
            out["spoken"] = spoken
        return out

    def get_progress(self) -> dict[str, Any]:
        if self.profile is None:
            return {"available": False, "reason": "no workout data yet"}
        out: dict[str, Any] = {
            "available": True,
            "activity": self.profile.name,
            "phase": self.phase_label(),
            "elapsed_s": round(self.state.elapsed_s, 1),
            "state": str(self.state.latest.state) if self.state.latest else None,
            "data_current": not self.state.is_stale(),
        }
        if (d := self.state.distance_m) is not None:
            out["distance_m"] = round(d, 1)
        if goal := self.targets.get(GOAL_KEY):
            out["goal_distance_m"] = goal
            if d is not None:
                out["remaining_m"] = round(max(0.0, goal - d), 1)
        out["splits"] = [self._split_dict(s) for s in self.state.splits[-5:]]
        out["targets"] = self.profile.describe_targets(self.targets)
        now = self._clock()
        if self.queue.is_quiet(now):
            out["quiet_remaining_s"] = round(self.queue.quiet_remaining_s(now))
        return out

    def _split_dict(self, split: Any) -> dict[str, Any]:
        out = {"index": split.index, "duration_s": round(split.duration_s, 1)}
        out |= {k: round(v, 1) for k, v in split.means.items() if k != "alt_m"}
        return out

    def set_quiet(self, minutes: float) -> dict[str, Any]:
        minutes = max(0.0, min(float(minutes), QUIET_MAX_MIN))
        self.queue.set_quiet(minutes * 60, self._clock())
        return {"quiet": minutes > 0, "minutes": minutes, "emergencies_still_announced": True}

    def end_workout_summary(self) -> dict[str, Any]:
        if self.profile is None or self.state.latest is None:
            return {"available": False, "reason": "no workout data yet"}
        out: dict[str, Any] = {
            "available": True,
            "activity": self.profile.name,
            "state": str(self.state.latest.state),
            "elapsed_s": round(self.state.elapsed_s, 1),
        }
        if (d := self.state.distance_m) is not None:
            out["distance_m"] = round(d, 1)
        for spec in self.profile.metrics:
            if (mean := self.state.session_mean(spec.field)) is not None and (
                spoken := spec.read(mean)
            ):
                out[f"avg_{spec.field}"] = round(mean, 2)
                out[f"avg_{spec.field}_spoken"] = spoken
        if (energy := self.state.latest.energy_kcal) is not None:
            out["energy_kcal"] = round(energy)
        splits = self.state.splits
        out["splits"] = [self._split_dict(s) for s in splits]
        if splits:
            fastest = min(splits, key=lambda s: s.duration_s)
            slowest = max(splits, key=lambda s: s.duration_s)
            out["fastest_split"] = fastest.index
            out["slowest_split"] = slowest.index
        out["alerts"] = dict(self.alerts)
        return out

    def run_profile_tool(self, name: str, args: Mapping[str, Any]) -> dict[str, Any]:
        if self.profile is None:
            return {"ok": False, "reason": "no workout running yet"}
        tool = next((t for t in self.profile.tools if t.name == name), None)
        if tool is None:
            return {"ok": False, "reason": f"{name} is not available for {self.profile.name}"}
        return tool.handler(self, args)
