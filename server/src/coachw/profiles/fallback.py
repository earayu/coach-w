"""Fallback profile for every activity without its own profile (spec 5.2).

Minimal on purpose: companion mode, heart rate and time only, one safety rule. The full fallback
profile (and walking / cycling) is M4.
"""

from __future__ import annotations

from coachw.coach.events import Alert, Sustained
from coachw.profiles.base import ActivityProfile, Athlete, Cadence, MetricSpec, Mode, Phase
from coachw.protocol import CuePriority, Haptic

DEFAULT_MAX_HR_BPM = 190.0
HR_EMERGENCY = "hr_emergency_bpm"


def _defaults(athlete: Athlete) -> dict[str, float]:
    return {HR_EMERGENCY: round((athlete.max_hr_bpm or DEFAULT_MAX_HR_BPM) * 0.97)}


FALLBACK = ActivityProfile(
    name="fallback",
    label="运动",
    activity_types=(),
    mode=Mode.COMPANION,
    metrics=(MetricSpec("hr_bpm", "心率", lambda v: f"{v:.0f}"),),
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
            alert=Alert(CuePriority.EMERGENCY, 90, 15, Haptic.FAILURE, "心率过高"),
            facts=lambda v, t, s: (
                f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于安全上限 {t:.0f}。让用户放慢、休息一下。"
            ),
        ),
    ),
    cadence=Cadence(
        companion_s=300, stable_multiplier=1.5, stable_after_s=300, max_per_minute=2, min_gap_s=15
    ),
    prompt="当前运动没有专门的档案，你是陪伴模式：以聊天为主，偶尔关心用户的状态，几乎不纠正。\n",
    companion_topics=("问用户现在感觉怎么样。", "简单鼓励用户，陪他聊两句。"),
    default_targets=_defaults,
)
