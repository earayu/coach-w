"""CoachBrain: one athlete's coaching state for one session.

Wires MetricsState → Director + EventEngine → CueQueue for the profile matching the workout's
`activity`, and answers the coach tools. No LiveKit here: the agent module feeds frames in, asks
`tick()` once a second what to say, and turns a release into speech and a watch cue.
"""

from __future__ import annotations

import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, tzinfo
from typing import Any
from zoneinfo import ZoneInfo

from coachw.coach.cue_queue import Cue, CueQueue, Release
from coachw.coach.director import GOAL_KEY, Director
from coachw.coach.events import CoachEvent, EventEngine, RuleContext
from coachw.coach.format import format_pace, say_distance, say_duration, speed_kmh
from coachw.coach.metrics_state import JOINED_AT_START_S, Climb, MetricsState
from coachw.coach.requests import Request, Requests
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

STATUS_PREFIX = "【运动状态，仅供参考，不要回复，用户没问就不要念】"

# Workout time going back by more than this (on a newer frame) means a new workout started.
NEW_WORKOUT_REWIND_S = 5.0

# The athlete's local time; the phone does not send its time zone yet.
DEFAULT_TZ = ZoneInfo("Asia/Shanghai")

# Terrain is described from the last 1 min (or 3 min for gentle climbs); flatter than this is flat.
CLIMB_WINDOW_S = 60.0
CLIMB_MENTION_GRADE = 0.02
CLIMB_MENTION_M = 3.0
CLIMB_LONG_WINDOW_S = 180.0
CLIMB_LONG_MENTION_M = 6.0
SESSION_ALT_MENTION_M = 10.0

# A due request is worth saying for this long, then the next one comes.
REQUEST_TTL_S = 20.0
CHECK_IN_TTL_S = 15.0
# Proactive check-in / companion backoff caps when the athlete stays silent.
CHECK_IN_MAX_S = 420.0
COMPANION_MAX_S = 480.0

CHECK_IN_FACTS = (
    "定时检查，不是用户说的话。想一想现在要不要主动说一句：用户交代过的事、"
    "数据里值得提的新变化（心率、配速、坡度、跑姿）、这个阶段该怎么跑，或者简短陪聊一句。"
    "不要重复已经报过的分段、掉速或已经问过的问题；没什么新变化或值得说的，就只输出 SKIP。"
)

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

    @property
    def optional(self) -> bool:
        """A wake-up the cue writer may answer with nothing (spec 4.2.2)."""
        return self.cue.event.optional


def describe_climb(
    climb: Climb | None,
    *,
    window_label: str = "最近一分钟",
    min_alt_m: float = CLIMB_MENTION_M,
) -> str | None:
    """ "最近一分钟在上坡，海拔升了 5 米，坡度约 4%" for a real slope, else None."""
    if (
        climb is None
        or abs(climb.grade) < CLIMB_MENTION_GRADE
        or abs(climb.alt_change_m) < min_alt_m
    ):
        return None
    way, verb = ("上坡", "升") if climb.alt_change_m > 0 else ("下坡", "降")
    return (
        f"{window_label}在{way}，海拔{verb}了 {abs(climb.alt_change_m):.0f} 米，"
        f"坡度约 {abs(climb.grade) * 100:.0f}%"
    )


def cue_instructions(cue: Cue, activity: str | None = None, terrain: str | None = None) -> str:
    # The realtime model does not apply common sense unless asked at the moment it speaks: told
    # once in the system prompt, it still praised a bike ride's 4'22" "kilometre" at 72 steps a
    # minute (COCH-15, measured on qwen-audio-3.1-realtime-flash). Safety cues stay immediate.
    check = (
        ""
        if cue.priority is CuePriority.EMERGENCY or activity is None
        else f"说之前先用常识想一想，这些数据放在用户正在做的{activity}里说不说得通；"
        "说不通就直说哪里不对、问用户怎么回事，不要夸。"
    )
    # a slope explains a higher heart rate and a slower pace (COCH-22)
    ground = (
        f"地形：{terrain}，评价心率和配速时考虑进去。\n"
        if terrain and cue.priority is not CuePriority.EMERGENCY
        else ""
    )
    return (
        f"【教练提示】{cue.event.facts}\n{ground}"
        f"{check}{PRIORITY_TONE[cue.priority]}。用自然的中文口语对用户说出来，"
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
        tz: tzinfo = DEFAULT_TZ,
        check_in_s: float | None = None,
    ) -> None:
        self.athlete = athlete
        self.tz = tz
        self.check_in_s = check_in_s
        """Wake the coach this long after anyone last spoke; it may stay silent (spec 4.2.2)."""
        self.requests = Requests()
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
        self._unanswered_proactive = 0
        self.alerts: dict[str, int] = {}
        self.profile_version = 0
        self.resumed: CoachResume | None = None

    # -- input ---------------------------------------------------------------------------------

    def on_frame(self, frame: MetricsFrame) -> bool:
        latest = self.state.latest
        if latest and (frame.ts, frame.seq) <= (latest.ts, latest.seq):
            return False
        if (
            self.profile is None
            or frame.activity not in self.profile.activity_types
            or self._starts_new_workout(latest, frame)
        ):
            self._load(self._profiles(frame.activity))
        first_frame = self.state.latest is None
        updated = self.state.update(frame)
        if first_frame and frame.distance_m is not None and frame.elapsed_s > JOINED_AT_START_S:
            self.requests.sync_distance(frame.distance_m)
        return updated

    def _starts_new_workout(self, latest: MetricsFrame | None, frame: MetricsFrame) -> bool:
        """The voice session outlives a workout: the next one must not inherit its state (its
        samples were ignored until their time passed the old workout's, and start never fired)."""
        if latest is None:
            return (
                self.resumed is not None
                and frame.elapsed_s + NEW_WORKOUT_REWIND_S < self.resumed.elapsed_s
            )
        if latest.state is WorkoutState.ENDED:
            return frame.state is not WorkoutState.ENDED
        # the end frame was lost: workout time only runs backwards when a new workout began
        return frame.elapsed_s + NEW_WORKOUT_REWIND_S < latest.elapsed_s

    def _load(self, profile: ActivityProfile) -> None:
        """A new activity starts a fresh coaching state; quiet mode carries over."""
        quiet_until = self.queue.quiet_until
        self.profile = profile
        self.targets = profile.default_targets(self.athlete)
        self.state = MetricsState(
            split_m=profile.split_m,
            baseline_s=profile.baseline_s,
            clock=self._clock,
            moving=profile.moving,
        )
        self.director = Director(profile)
        self.engine = EventEngine(profile.rules)
        c = profile.cadence
        self.queue = CueQueue(max_per_minute=c.max_per_minute, min_gap_s=c.min_gap_s)
        self.queue.quiet_until = quiet_until
        self.alerts = {}
        self._unanswered_proactive = 0
        self.resumed = None
        self.profile_version += 1

    def resume(self, resume: CoachResume) -> bool:
        """Carry on a workout an earlier session coached (spec 7.4). Returns whether it applied."""
        if self.resumed is not None:
            return False
        if resume.elapsed_s <= JOINED_AT_START_S:
            # the phone connects the coach as the workout starts (spec 7.6): this session sees
            # it from the start itself, and greets the start instead of "I'm back"
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
        if resume.distance_m is not None:
            self.requests.sync_distance(resume.distance_m)
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

    def note_athlete_spoke(self) -> None:
        """Reset proactive backoff once the athlete speaks."""
        self._unanswered_proactive = 0
        self.last_talk_at = self._clock()

    def note_check_in_skipped(self) -> None:
        """A check-in answered with SKIP did not nag the athlete; undo its backoff increment."""
        if self._unanswered_proactive > 0:
            self._unanswered_proactive -= 1

    def _proactive_backoff(self) -> float:
        return float(2 ** min(self._unanswered_proactive, 3))

    def _effective_check_in_s(self) -> float | None:
        if not self.check_in_s:
            return None
        return min(self.check_in_s * self._proactive_backoff(), CHECK_IN_MAX_S)

    def _companion_backoff(self) -> float:
        if self.profile is None or self.profile.cadence.companion_s <= 0:
            return 1.0
        return min(self._proactive_backoff(), COMPANION_MAX_S / self.profile.cadence.companion_s)

    def tick(self, *, user_speaking: bool, agent_speaking: bool) -> Delivery | None:
        """Evaluate the timeline and rules, then release at most one cue."""
        if self.profile is None or self.director is None or self.engine is None:
            return None
        now = self._clock()
        if user_speaking:
            self._unanswered_proactive = 0
        if user_speaking or agent_speaking:
            # a conversation counts as talk: companion chat waits its interval after it too
            self.last_talk_at = now
        ctx = RuleContext(self.state, self.targets)
        since_spoken = now - max(
            self.queue.last_spoken_at or self.started_at, self.last_talk_at or self.started_at
        )
        since_alert = now - (self.queue.last_alert_at or self.started_at)
        events = self.engine.evaluate(ctx) + self.director.evaluate(
            self.state,
            self.targets,
            since_spoken_s=since_spoken,
            since_alert_s=since_alert,
            quiet_backoff=self._companion_backoff(),
        )
        if self.state.is_running and self.state.moving_started and not self.state.is_stale():
            due = self.requests.due(now, distance_m=self.state.distance_m)
            events = self._merge_due_requests(events, due)
            check_in_interval = self._effective_check_in_s()
            if check_in_interval and since_spoken >= check_in_interval:
                events.append(self._check_in_event(check_in_interval))
        for event in events:
            self.queue.offer(event, now)
        release = self.queue.next(now, user_speaking=user_speaking, agent_speaking=agent_speaking)
        if release is None:
            return None
        if release.cue.priority is CuePriority.COMPANION:
            self.director.companion_spoken()
            self._unanswered_proactive += 1
        return self._deliver(release)

    def _merge_due_requests(self, events: list[CoachEvent], due: list[Request]) -> list[CoachEvent]:
        if not due:
            return events
        split_idx = next(
            (i for i in range(len(events) - 1, -1, -1) if events[i].kind.startswith("split:")),
            None,
        )
        folded: list[Request] = []
        standalone: list[Request] = []
        for r in due:
            if split_idx is not None and r.every_m is not None:
                folded.append(r)
            else:
                standalone.append(r)
        out = list(events)
        if folded and split_idx is not None:
            ev = out[split_idx]
            readings = self.readings()
            extra = "；".join(f"「{r.text}」" for r in folded)
            live = f"（此刻实时数据：{readings}）" if readings else ""
            out[split_idx] = CoachEvent(
                kind=ev.kind,
                priority=ev.priority,
                facts=f"{ev.facts} 另外用户要求每段{extra}{live}，一并说到。",
                cooldown_key=ev.cooldown_key,
                cooldown_s=ev.cooldown_s,
                ttl_s=ev.ttl_s,
                haptic=ev.haptic,
                watch_text=ev.watch_text,
                optional=ev.optional,
            )
        out += [self._request_event(r) for r in standalone]
        return out

    def add_request(
        self,
        text: str,
        *,
        every_s: float | None = None,
        every_m: float | None = None,
        lasting: bool = False,
    ) -> Request | None:
        return self.requests.add(
            text,
            every_s=every_s,
            every_m=every_m,
            lasting=lasting,
            now=self._clock(),
            distance_m=self.state.distance_m,
        )

    def restore_requests(self, saved: list[Request]) -> None:
        """Requests an earlier session was given (athlete memory); timers start from now."""
        self.requests.restore(saved, self._clock(), distance_m=self.state.distance_m)

    def _request_event(self, request: Request) -> CoachEvent:
        readings = self.readings()
        data = f"手表此刻的数据：{readings}。" if readings else "手表此刻没有实时数据。"
        trigger = "到距离了" if request.every_m and not request.every_s else "到时间了"
        return CoachEvent(
            kind="request",
            priority=CuePriority.MILESTONE,
            facts=(
                f"用户之前要求：「{request.text}」，现在{trigger}。{data}"
                "照他的要求说，只说他要的那几项，一句话。"
            ),
            cooldown_key=f"request:{request.id}",
            cooldown_s=0.0,
            ttl_s=REQUEST_TTL_S,
        )

    def _check_in_event(self, cooldown_s: float) -> CoachEvent:
        return CoachEvent(
            kind="check_in",
            priority=CuePriority.COMPANION,
            facts=CHECK_IN_FACTS,
            cooldown_key="check_in",
            cooldown_s=cooldown_s,
            ttl_s=CHECK_IN_TTL_S,
            optional=True,
        )

    def _terrain_summary(self) -> str | None:
        return describe_climb(self.state.climb(CLIMB_WINDOW_S)) or describe_climb(
            self.state.climb(CLIMB_LONG_WINDOW_S),
            window_label="最近三分钟",
            min_alt_m=CLIMB_LONG_MENTION_M,
        )

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
        label = self.profile.label if self.profile else None
        terrain = self._terrain_summary()
        return Delivery(cue, cue_instructions(cue, label, terrain), release.interrupt, watch)

    # -- summaries and tools -------------------------------------------------------------------

    def phase_label(self) -> str:
        if self.director is None:
            return "未开始"
        if self.state.latest and self.state.latest.state is WorkoutState.ENDED:
            return "结束"
        phase = self.director.current_phase(self.state, self.targets)
        return phase.label if phase else "准备"

    def workout_in_progress(self) -> bool:
        """A workout the watch is recording now: running or paused, with fresh frames."""
        latest = self.state.latest
        return (
            latest is not None
            and latest.state is not WorkoutState.ENDED
            and not self.state.is_stale()
        )

    def status_summary(self) -> str | None:
        """Context for the model, injected without a reply. It carries the watch's live readings
        as they are now; the loop replaces it the moment the athlete starts speaking, so a
        question is answered from what the watch shows at that moment (spec 4.2, COCH-18)."""
        # the model has no clock of its own (COCH-22: "you have no sense of time")
        clock = f"现在时间 {self.local_time()}"
        asked = [f"用户交代过：{'；'.join(r.describe() for r in self.requests.items)}"]
        asked = asked if self.requests.items else []
        if self.profile is None or self.state.latest is None:
            # before the watch starts: the coach chats about the plan, not live numbers (spec 7.6)
            return (
                f"{STATUS_PREFIX}{'；'.join([clock, *asked])}；"
                "还没开始运动：手表还没开始记录，没有任何运动数据。"
            )
        parts = [clock, f"运动：{self.profile.label}", f"阶段：{self.phase_label()}"]
        parts.append(f"workout 状态：{self.state.latest.state}")
        if self.state.started:
            parts.append(f"手表已计时约 {say_duration(self.state.elapsed_s)}")
            parts += self._moving_parts()
        if (d := self.state.distance_m) is not None:
            parts.append(f"已完成约 {say_distance(d)}")
        if self.state.splits:
            parts.append(f"已完成第 {self.state.splits[-1].index} {self.profile.split_label}")
        if goals := self.profile.describe_targets(self.targets):
            parts.append(f"目标：{'，'.join(goals)}")
        if self.state.is_stale() and self.state.is_running:
            parts.append("手表数据暂时中断")
        now = self._clock()
        if self.queue.is_quiet(now):
            parts.append(f"用户要求安静，还剩约 {say_duration(self.queue.quiet_remaining_s(now))}")
        if terrain := self._terrain_summary():
            parts.append(f"地形：{terrain}")
        ascent, descent = self.state.session_ascent_m, self.state.session_descent_m
        if (ascent and ascent >= SESSION_ALT_MENTION_M) or (
            descent and descent >= SESSION_ALT_MENTION_M
        ):
            alt_bits = []
            if ascent and ascent >= SESSION_ALT_MENTION_M:
                alt_bits.append(f"累计爬升约 {ascent:.0f} 米")
            if descent and descent >= SESSION_ALT_MENTION_M:
                alt_bits.append(f"累计下降约 {descent:.0f} 米")
            parts.append("海拔：" + "，".join(alt_bits))
        parts += asked
        if readings := self.readings():
            parts.append(f"手表此刻的实时数据：{readings}")
        else:
            parts.append("手表此刻没有心率等实时数据")
        return STATUS_PREFIX + "；".join(parts) + "。"

    def local_time(self) -> str:
        return datetime.fromtimestamp(self._wall_ms() / 1000, self.tz).strftime("%H:%M:%S")

    def readings(self) -> str | None:
        """The live readings as said aloud, or None while there are none."""
        metrics = self.get_metrics()
        if metrics["available"] and metrics.get("live_readings", True) and metrics.get("spoken"):
            return "，".join(f"{label} {text}" for label, text in metrics["spoken"].items())
        return None

    def _moving_parts(self) -> list[str]:
        """The watch may have started well before the athlete did (COCH-22: in a car)."""
        if self.profile is None or self.profile.moving is None:
            return []
        since = self.state.moving_since_s
        if since is None:
            return [
                f"但还没看到用户在{self.profile.label}（步频、速度对不上），实际运动时间还没开始算"
            ]
        if since < JOINED_AT_START_S:
            return []
        return [
            f"用户从手表计时 {say_duration(since)} 起才真正开始{self.profile.label}，"
            f"实际{self.profile.label}了约 {say_duration(self.state.effort_s)}"
        ]

    def get_metrics(self) -> dict[str, Any]:
        out = self.state.snapshot()
        if not out["available"] or self.profile is None:
            return out
        if not self.profile.speed_as_pace:
            out.pop("pace_per_km", None)
            if (speed := out.get("speed_mps")) is not None:
                out["speed_kmh"] = round(speed_kmh(speed), 1)
        if climb := self.state.climb(CLIMB_WINDOW_S):
            out["alt_change_1min_m"] = round(climb.alt_change_m, 1)
            out["grade_pct"] = round(climb.grade * 100, 1)
        if climb3 := self.state.climb(CLIMB_LONG_WINDOW_S):
            out["alt_change_3min_m"] = round(climb3.alt_change_m, 1)
            out["grade_3min_pct"] = round(climb3.grade * 100, 1)
        if (ascent := self.state.session_ascent_m) is not None:
            out["session_ascent_m"] = round(ascent, 1)
        if (descent := self.state.session_descent_m) is not None:
            out["session_descent_m"] = round(descent, 1)
        if (net := self.state.session_net_alt_m) is not None:
            out["session_net_alt_m"] = round(net, 1)
        # how the profile says each metric, so the model reads e.g. km/h on a bike
        spoken = {
            spec.label: text
            for spec in self.profile.metrics
            if (value := out.get(spec.field)) is not None and (text := spec.read(value))
        }
        if spoken:
            out["spoken"] = spoken
        return out

    def get_trend(self, minutes: int = 5) -> dict[str, Any]:
        """Per-minute recent trend of HR, pace/speed, cadence and altitude, plus session climb."""
        if self.profile is None or self.state.latest is None:
            return {"available": False, "reason": "no workout data yet"}
        raw_buckets = self.state.trend(minutes)
        if not raw_buckets:
            return {"available": False, "reason": "not enough samples yet"}
        buckets: list[dict[str, Any]] = []
        for row in raw_buckets:
            item = dict(row)
            if (spd := item.pop("avg_speed_mps", None)) is not None:
                if self.profile.speed_as_pace:
                    if pace := format_pace(spd):
                        item["avg_pace_per_km"] = pace
                else:
                    item["avg_speed_kmh"] = round(speed_kmh(spd), 1)
            buckets.append(item)
        out: dict[str, Any] = {
            "available": True,
            "activity": self.profile.name,
            "minutes": len(buckets),
            "per_minute": buckets,
        }
        if climb := self.state.climb(CLIMB_WINDOW_S):
            out["climb_1min"] = {
                "alt_change_m": round(climb.alt_change_m, 1),
                "grade_pct": round(climb.grade * 100, 1),
            }
        if climb3 := self.state.climb(CLIMB_LONG_WINDOW_S):
            out["climb_3min"] = {
                "alt_change_m": round(climb3.alt_change_m, 1),
                "grade_pct": round(climb3.grade * 100, 1),
            }
        if (ascent := self.state.session_ascent_m) is not None:
            out["session_ascent_m"] = round(ascent, 1)
        if (descent := self.state.session_descent_m) is not None:
            out["session_descent_m"] = round(descent, 1)
        if (net := self.state.session_net_alt_m) is not None:
            out["session_net_alt_m"] = round(net, 1)
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
        if self.profile.moving is not None:
            since = self.state.moving_since_s
            out["moving_since_elapsed_s"] = None if since is None else round(since, 1)
            out["active_s"] = round(self.state.effort_s, 1)
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
