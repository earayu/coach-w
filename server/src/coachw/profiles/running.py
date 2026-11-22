"""Running profile, P0 (spec 5.2): coach mode, kilometre splits, heart-rate / pace / form rules."""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from typing import TYPE_CHECKING, Any

from coachw.coach.director import GOAL_KEY
from coachw.coach.events import Alert, SplitTrend, Sustained, WindowVsBaseline, WindowVsTarget
from coachw.coach.format import (
    format_pace_seconds,
    pace_seconds,
    say_distance,
    say_duration,
    say_pace,
)
from coachw.coach.metrics_state import Split
from coachw.profiles.base import (
    ActivityProfile,
    Athlete,
    Cadence,
    MetricSpec,
    Mode,
    Phase,
    ProfileTool,
)
from coachw.protocol import CuePriority, Haptic

if TYPE_CHECKING:
    from coachw.coach.brain import CoachBrain

# Placeholder until the phone sends the athlete's own maximum heart rate (spec 3.1, 14.2).
DEFAULT_MAX_HR_BPM = 190.0
HR_CEILING_SHARE = 0.90
HR_EMERGENCY_SHARE = 0.97

WARMUP_S = 600.0

HR_CEILING = "hr_ceiling_bpm"
HR_EMERGENCY = "hr_emergency_bpm"
TARGET_SPEED = "target_speed_mps"

PACE_MIN_S = 150  # 2'30" per km
PACE_MAX_S = 900  # 15'00" per km
GOAL_MAX_KM = 100


def _defaults(athlete: Athlete) -> dict[str, float]:
    max_hr = athlete.max_hr_bpm or DEFAULT_MAX_HR_BPM
    return {
        HR_CEILING: round(max_hr * HR_CEILING_SHARE),
        HR_EMERGENCY: round(max_hr * HR_EMERGENCY_SHARE),
    }


def _describe(targets: Mapping[str, float]) -> list[str]:
    out = []
    if speed := targets.get(TARGET_SPEED):
        out.append(f"配速{say_pace(1000 / speed)}")
    if goal := targets.get(GOAL_KEY):
        out.append(f"距离 {say_distance(goal)}")
    if ceiling := targets.get(HR_CEILING):
        out.append(f"心率不超过 {ceiling:.0f}")
    return out


def _split_facts(split: Split) -> str:
    text = f"完成第 {split.index} 公里，这一公里用时 {say_duration(split.duration_s)}"
    if (hr := split.means.get("hr_bpm")) is not None:
        text += f"，平均心率 {hr:.0f}"
    if (cadence := split.means.get("cadence_spm")) is not None:
        text += f"，平均步频每分钟 {cadence:.0f} 步"
    return text + "。播报这一公里的用时，简短点评。"


def _pace_trend_facts(values: Sequence[float], splits: Sequence[Split]) -> str:
    times = "、".join(say_duration(v) for v in values)
    first, last = splits[0].index, splits[-1].index
    return (
        f"第 {first} 到第 {last} 公里的用时依次是 {times}，每公里都比上一公里慢。"
        "提醒用户注意节奏，评估是否需要调整目标。"
    )


def adjust_target_pace(brain: CoachBrain, args: Mapping[str, Any]) -> dict[str, Any]:
    """Set (or clear with 0:00) the target pace, optionally with today's goal distance."""
    try:
        minutes, seconds = int(args.get("pace_min", 0)), int(args.get("pace_sec", 0))
        goal_km = args.get("goal_km")
        goal_km = None if goal_km is None else float(goal_km)
    except (TypeError, ValueError):
        return {"ok": False, "reason": "pace_min / pace_sec must be integers, goal_km a number"}
    total = minutes * 60 + seconds
    # validate everything before changing anything: a rejected call must not half-apply
    if not (0 <= seconds < 60) or (total and not PACE_MIN_S <= total <= PACE_MAX_S):
        return {"ok": False, "reason": "pace must be between 2'30\" and 15'00\" per km"}
    if goal_km is not None and not (goal_km == 0 or 0 < goal_km <= GOAL_MAX_KM):
        return {"ok": False, "reason": f"goal_km must be between 0 and {GOAL_MAX_KM}"}
    if total == 0:
        brain.targets.pop(TARGET_SPEED, None)
    else:
        brain.targets[TARGET_SPEED] = 1000 / total
    if goal_km == 0:
        brain.targets.pop(GOAL_KEY, None)
    elif goal_km is not None:
        brain.targets[GOAL_KEY] = goal_km * 1000
    out: dict[str, Any] = {"ok": True}
    out["target_pace_per_km"] = format_pace_seconds(total) if total else None
    out["goal_distance_m"] = brain.targets.get(GOAL_KEY)
    return out


ADJUST_TARGET_PACE = ProfileTool(
    name="adjust_target_pace",
    description=(
        "设置或修改用户本次跑步的目标配速（每公里几分几秒），可同时设置今天的目标距离。"
        "用户说出目标配速、想跑快一点或慢一点、或说今天要跑几公里时调用。"
        "pace_min 和 pace_sec 都传 0 表示取消目标配速；goal_km 传 0 表示取消目标距离。"
    ),
    parameters={
        "type": "object",
        "properties": {
            "pace_min": {"type": "integer", "description": "目标配速的分钟部分，如 5'30\" 传 5"},
            "pace_sec": {"type": "integer", "description": "目标配速的秒部分，如 5'30\" 传 30"},
            "goal_km": {"type": "number", "description": "可选，今天的目标距离（公里）"},
        },
        "required": ["pace_min", "pace_sec"],
    },
    handler=adjust_target_pace,
)

PROMPT = """\
当前运动是跑步，你是教练模式：有目标，主动纠正和鼓励。
- 配速读作"每公里几分几秒"；步频读作"每分钟多少步"；距离超过一千米读成公里。
- 用户说出目标配速、想调整快慢、或说今天要跑几公里时，调用 adjust_target_pace。
- 心率过高时安全优先，让用户放慢或停下走一走。
"""

RUNNING = ActivityProfile(
    name="running",
    label="跑步",
    activity_types=("running",),
    mode=Mode.COACH,
    metrics=(
        MetricSpec("hr_bpm", "心率", lambda v: f"{v:.0f}"),
        MetricSpec("speed_mps", "配速", lambda v: (s := pace_seconds(v)) and say_pace(s)),
        MetricSpec("cadence_spm", "步频", lambda v: f"每分钟 {v:.0f} 步"),
        MetricSpec("power_w", "功率", lambda v: f"{v:.0f} 瓦"),
        MetricSpec("stride_m", "步幅", lambda v: f"{v:.2f} 米"),
        MetricSpec("gct_ms", "触地时间", lambda v: f"{v:.0f} 毫秒"),
        MetricSpec("vo_cm", "垂直振幅", lambda v: f"{v:.1f} 厘米"),
    ),
    phases=(
        Phase("warmup", "热身", after_s=0),
        Phase("main", "主训练", after_s=WARMUP_S),
        Phase("cooldown", "放松", goal_fraction=0.9),
    ),
    split_m=1000.0,
    split_label="公里",
    split_facts=_split_facts,
    rules=(
        Sustained(
            kind="hr_emergency",
            field="hr_bpm",
            threshold=HR_EMERGENCY,
            for_s=15,
            alert=Alert(CuePriority.EMERGENCY, 90, 15, Haptic.FAILURE, "心率过高", key="hr_high"),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于安全上限 {t:.0f}。"
                "立刻让用户放慢，必要时停下来走一走。"
            ),
        ),
        Sustained(
            kind="hr_ceiling",
            field="hr_bpm",
            threshold=HR_CEILING,
            for_s=30,
            alert=Alert(
                CuePriority.CORRECTION, 180, 20, Haptic.DIRECTION_DOWN, "心率偏高", key="hr_high"
            ),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于目标上限 {t:.0f}。建议放慢一点、调整呼吸。"
            ),
        ),
        WindowVsTarget(
            kind="pace_slow",
            field="speed_mps",
            window_s=60,
            target=TARGET_SPEED,
            tolerance=15,
            direction=+1,
            transform=pace_seconds,
            alert=Alert(
                CuePriority.CORRECTION,
                180,
                20,
                Haptic.DIRECTION_UP,
                "配速偏慢",
                key="pace_target",
                after_s=WARMUP_S,
            ),
            facts=lambda v, g, d: (
                f"最近一分钟平均配速{say_pace(v)}，比目标{say_pace(g)}慢 {d:.0f} 秒。"
                "鼓励用户稍微提一点速度。"
            ),
        ),
        WindowVsTarget(
            kind="pace_fast",
            field="speed_mps",
            window_s=60,
            target=TARGET_SPEED,
            tolerance=15,
            direction=-1,
            transform=pace_seconds,
            alert=Alert(
                CuePriority.CORRECTION,
                180,
                20,
                Haptic.DIRECTION_DOWN,
                "配速偏快",
                key="pace_target",
                after_s=WARMUP_S,
            ),
            facts=lambda v, g, d: (
                f"最近一分钟平均配速{say_pace(v)}，比目标{say_pace(g)}快 {-d:.0f} 秒。"
                "提醒用户收一收，留着体力。"
            ),
        ),
        SplitTrend(
            kind="pace_drift",
            metric=lambda s: s.duration_s,
            steps=2,
            min_step=10,
            direction=+1,
            alert=Alert(CuePriority.CORRECTION, 600, 30, Haptic.DIRECTION_UP, "持续掉速"),
            facts=_pace_trend_facts,
        ),
        WindowVsBaseline(
            kind="cadence_drop",
            field="cadence_spm",
            window_s=60,
            change=-0.05,
            alert=Alert(CuePriority.CORRECTION, 300, 20, Haptic.DIRECTION_UP, "步频下降"),
            facts=lambda v, b, c: (
                f"最近一分钟平均步频每分钟 {v:.0f} 步，比前段的 {b:.0f} 步低了 {-c * 100:.0f}%。"
                "提醒用户步子小一点、频率快一点。"
            ),
        ),
        WindowVsBaseline(
            kind="gct_rise",
            field="gct_ms",
            window_s=120,
            change=0.08,
            alert=Alert(CuePriority.CORRECTION, 600, 30, Haptic.NOTIFICATION, "注意跑姿"),
            facts=lambda v, b, c: (
                f"最近两分钟平均触地时间 {v:.0f} 毫秒，比前段的 {b:.0f} 毫秒增加了 {c * 100:.0f}%，"
                "可能开始疲劳、跑姿走样。提醒用户身体微微前倾、轻快落地。"
            ),
        ),
    ),
    cadence=Cadence(
        companion_s=240,
        stable_multiplier=1.5,
        stable_after_s=300,
        max_per_minute=3,
        min_gap_s=10,
    ),
    prompt=PROMPT,
    companion_topics=(
        "问用户现在感觉怎么样，呼吸顺不顺。",
        "做一次谈话测试：请用户说一句完整的话，看看还能不能轻松说话。",
        "提醒用户放松肩膀，手臂自然前后摆动。",
        "简单鼓励用户，保持现在的节奏。",
    ),
    default_targets=_defaults,
    describe_targets=_describe,
    tools=(ADJUST_TARGET_PACE,),
)
