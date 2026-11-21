"""Fallback profile for every activity without its own profile (spec 5.2).

Companion mode built only on what every workout has: heart rate, time and energy. No distance
splits (many activities have no distance); a time mark every 10 minutes instead.
"""

from __future__ import annotations

from coachw.coach.events import Alert, Sustained
from coachw.profiles.base import ActivityProfile, Athlete, Cadence, MetricSpec, Mode, Phase
from coachw.protocol import CuePriority, Haptic

# Placeholder until the phone sends the athlete's own maximum heart rate (spec 3.1, 14.2).
DEFAULT_MAX_HR_BPM = 190.0
HR_CEILING_SHARE = 0.90
HR_EMERGENCY_SHARE = 0.97
HR_CEILING = "hr_ceiling_bpm"
HR_EMERGENCY = "hr_emergency_bpm"

TIME_MARK_S = 600.0


def _defaults(athlete: Athlete) -> dict[str, float]:
    max_hr = athlete.max_hr_bpm or DEFAULT_MAX_HR_BPM
    return {
        HR_CEILING: round(max_hr * HR_CEILING_SHARE),
        HR_EMERGENCY: round(max_hr * HR_EMERGENCY_SHARE),
    }


def _time_mark_facts(elapsed_s: float, energy_kcal: float | None) -> str:
    text = f"已经运动 {elapsed_s / 60:.0f} 分钟"
    if energy_kcal:
        text += f"，消耗了 {energy_kcal:.0f} 千卡"
    return text + "。轻松地告诉用户，鼓励一句。"


FALLBACK = ActivityProfile(
    name="fallback",
    label="运动",
    activity_types=(),
    mode=Mode.COMPANION,
    metrics=(
        MetricSpec("hr_bpm", "心率", lambda v: f"{v:.0f}"),
        MetricSpec("energy_kcal", "能量", lambda v: f"{v:.0f} 千卡"),
    ),
    phases=(Phase("active", "运动中", after_s=0),),
    split_m=None,
    split_label="段",
    split_facts=lambda s: f"完成第 {s.index} 段。",
    rules=(
        Sustained(
            kind="hr_emergency",
            field="hr_bpm",
            threshold=HR_EMERGENCY,
            for_s=15,
            alert=Alert(CuePriority.EMERGENCY, 90, 15, Haptic.FAILURE, "心率过高", key="hr_high"),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于安全上限 {t:.0f}。让用户放慢、休息一下。"
            ),
        ),
        Sustained(
            kind="hr_ceiling",
            field="hr_bpm",
            threshold=HR_CEILING,
            for_s=60,
            alert=Alert(
                CuePriority.CORRECTION, 600, 20, Haptic.DIRECTION_DOWN, "心率偏高", key="hr_high"
            ),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于 {t:.0f}。温和地提醒用户可以缓一缓。"
            ),
        ),
    ),
    cadence=Cadence(
        companion_s=300, stable_multiplier=1.5, stable_after_s=300, max_per_minute=2, min_gap_s=15
    ),
    prompt="""\
当前运动没有专门的档案，你是陪伴模式：以聊天为主，偶尔关心用户的状态，几乎不纠正。
- 只谈心率、用时和消耗的能量（千卡）；不要提距离、配速、速度，这类运动不一定有。
""",
    companion_topics=(
        "问用户现在感觉怎么样。",
        "简单鼓励用户，陪他聊两句。",
        "提醒用户注意呼吸，累了可以歇一下。",
    ),
    default_targets=_defaults,
    start_hint="简短地打个招呼，说你会陪着他，有需要随时说。",
    end_hint="用一句话总结并夸奖用户，提醒放松一下。",
    time_mark_s=TIME_MARK_S,
    time_mark_facts=_time_mark_facts,
)
