"""Cycling profile, P1 (spec 5.2): coach mode, very short lines, road safety first.

Speed is read as km/h. Cadence and power need Bluetooth sensors; without them the rules built on
those fields have no data and stay silent (spec 4.4).
"""

from __future__ import annotations

from coachw.coach.events import Alert, Sustained, WindowVsBaseline
from coachw.coach.format import say_duration, speed_kmh
from coachw.coach.metrics_state import Split
from coachw.profiles.base import ActivityProfile, Athlete, Cadence, MetricSpec, Mode, Phase
from coachw.protocol import CuePriority, Haptic

# Placeholder until the phone sends the athlete's own maximum heart rate (spec 3.1, 14.2).
DEFAULT_MAX_HR_BPM = 190.0
HR_CEILING_SHARE = 0.90
HR_EMERGENCY_SHARE = 0.97

WARMUP_S = 600.0

HR_CEILING = "hr_ceiling_bpm"
HR_EMERGENCY = "hr_emergency_bpm"


def _defaults(athlete: Athlete) -> dict[str, float]:
    max_hr = athlete.max_hr_bpm or DEFAULT_MAX_HR_BPM
    return {
        HR_CEILING: round(max_hr * HR_CEILING_SHARE),
        HR_EMERGENCY: round(max_hr * HR_EMERGENCY_SHARE),
    }


def say_speed(speed_mps: float) -> str:
    return f"每小时 {speed_kmh(speed_mps):.0f} 公里"


def _split_facts(split: Split) -> str:
    text = f"骑完第 {split.index * 5} 公里，这 5 公里用了 {say_duration(split.duration_s)}"
    if split.duration_s > 0:
        text += f"，平均{say_speed(5000 / split.duration_s)}"
    return text + "。一句话播报，越短越好。"


PROMPT = """\
当前运动是骑行，你是教练模式，但用户在路上骑车：安全第一。
- 每次只说一句很短的话，不要追问，不要讲长故事；路况复杂时用户可能顾不上回答。
- 速度读作"每小时多少公里"（工具结果的 speed_kmh 或 spoken 里的读法），不要说配速。
- 踏频读作"每分钟多少转"，功率读作"多少瓦"；没有踏频、功率传感器时不要提这两项。
- 提醒注意路况、红绿灯和车辆，不要鼓励用户在车流里加速。
"""

CYCLING = ActivityProfile(
    name="cycling",
    label="骑行",
    activity_types=("cycling",),
    spoken_names=("骑",),
    mode=Mode.COACH,
    metrics=(
        MetricSpec("hr_bpm", "心率", lambda v: f"{v:.0f}"),
        MetricSpec("speed_mps", "速度", lambda v: say_speed(v) if v >= 0.3 else None),
        MetricSpec("cadence_spm", "踏频", lambda v: f"每分钟 {v:.0f} 转"),
        MetricSpec("power_w", "功率", lambda v: f"{v:.0f} 瓦"),
        MetricSpec("alt_m", "海拔", lambda v: f"{v:.0f} 米"),
    ),
    phases=(
        Phase("warmup", "热身", after_s=0),
        Phase("main", "主骑行", after_s=WARMUP_S),
        Phase("cooldown", "放松", goal_fraction=0.9),
    ),
    split_m=5000.0,
    split_label="段",
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
                "让用户立刻减速，找安全的地方停下来休息。"
            ),
        ),
        Sustained(
            kind="hr_ceiling",
            field="hr_bpm",
            threshold=HR_CEILING,
            for_s=45,
            alert=Alert(
                CuePriority.CORRECTION, 240, 20, Haptic.DIRECTION_DOWN, "心率偏高", key="hr_high"
            ),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于目标上限 {t:.0f}。一句话提醒用户放轻一点。"
            ),
        ),
        WindowVsBaseline(
            kind="cadence_drop",
            field="cadence_spm",
            window_s=120,
            change=-0.10,
            alert=Alert(
                CuePriority.CORRECTION, 600, 20, Haptic.DIRECTION_UP, "踏频下降", after_s=WARMUP_S
            ),
            facts=lambda v, b, c: (
                f"最近两分钟平均踏频每分钟 {v:.0f} 转，比前段的 {b:.0f} 转低了 {-c * 100:.0f}%。"
                "一句话建议换轻一点的挡、踩得轻快些。"
            ),
        ),
        WindowVsBaseline(
            kind="power_drop",
            field="power_w",
            window_s=180,
            change=-0.15,
            alert=Alert(
                CuePriority.CORRECTION, 900, 20, Haptic.NOTIFICATION, "功率下降", after_s=WARMUP_S
            ),
            facts=lambda v, b, c: (
                f"最近三分钟平均功率 {v:.0f} 瓦，比前段的 {b:.0f} 瓦低了 {-c * 100:.0f}%，"
                "可能开始累了。一句话问用户状态，提醒补水补能量。"
            ),
        ),
    ),
    cadence=Cadence(
        companion_s=420,
        stable_multiplier=1.5,
        stable_after_s=300,
        max_per_minute=2,
        min_gap_s=20,
    ),
    prompt=PROMPT,
    companion_topics=(
        "一句话提醒用户注意前方路况。",
        "一句话问用户感觉怎么样。",
        "一句话提醒用户找安全的时机喝口水。",
    ),
    default_targets=_defaults,
    start_hint="一句话打气，提醒先轻松骑、注意路况。",
    end_hint="用一句话总结，提醒补水、拉伸，再问用户这次骑下来感觉怎么样。",
    speed_as_pace=False,
)
