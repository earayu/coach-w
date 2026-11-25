"""Walking and hiking profiles, P1 (spec 5.2): companion mode, mostly chat, rarely a correction.

The coach keeps the athlete company, mentions distance and time now and then, and cares about
safety. The only alert is the heart-rate safety limit; nothing corrects pace or form.
"""

from __future__ import annotations

from collections.abc import Mapping

from coachw.coach.events import Alert, Sustained
from coachw.coach.format import pace_seconds, say_duration, say_pace
from coachw.coach.metrics_state import Split
from coachw.profiles.base import ActivityProfile, Athlete, Cadence, MetricSpec, Mode, Phase
from coachw.protocol import CuePriority, Haptic

# Placeholder until the phone sends the athlete's own maximum heart rate (spec 3.1, 14.2).
DEFAULT_MAX_HR_BPM = 190.0
HR_EMERGENCY_SHARE = 0.97
HR_EMERGENCY = "hr_emergency_bpm"


# Looks like walking: steps, or a speed on foot; faster than a jog is a ride (COCH-22).
WALK_MIN_CADENCE_SPM = 50.0
WALK_SPEED_MPS = (0.4, 3.5)


def _walking(values: Mapping[str, float]) -> bool:
    speed, cadence = values.get("speed_mps"), values.get("cadence_spm")
    if speed is not None and speed > WALK_SPEED_MPS[1]:
        return False
    if cadence is not None:
        return cadence >= WALK_MIN_CADENCE_SPM
    return speed is not None and speed >= WALK_SPEED_MPS[0]


def _defaults(athlete: Athlete) -> dict[str, float]:
    return {HR_EMERGENCY: round((athlete.max_hr_bpm or DEFAULT_MAX_HR_BPM) * HR_EMERGENCY_SHARE)}


def _split_facts(split: Split) -> str:
    # time and distance only: a walk is not graded
    return (
        f"走完第 {split.index} 公里，这一公里用了 {say_duration(split.duration_s)}。"
        "轻松地顺口提一句，不用点评快慢，接着陪用户聊天。"
    )


METRICS = (
    MetricSpec("hr_bpm", "心率", lambda v: f"{v:.0f}"),
    MetricSpec("speed_mps", "配速", lambda v: (s := pace_seconds(v)) and say_pace(s)),
    MetricSpec("cadence_spm", "步频", lambda v: f"每分钟 {v:.0f} 步"),
    MetricSpec("alt_m", "海拔", lambda v: f"{v:.0f} 米"),
)

HR_EMERGENCY_RULE = Sustained(
    kind="hr_emergency",
    field="hr_bpm",
    threshold=HR_EMERGENCY,
    for_s=20,
    alert=Alert(CuePriority.EMERGENCY, 120, 15, Haptic.FAILURE, "心率过高"),
    facts=lambda v, t, s: (
        f"心率 {v:.0f}，已经连续 {s:.0f} 秒高于安全上限 {t:.0f}。"
        "关心地让用户停下来歇一会儿，问问有没有不舒服。"
    ),
)

CADENCE = Cadence(
    companion_s=300, stable_multiplier=1.5, stable_after_s=300, max_per_minute=2, min_gap_s=20
)

SAFETY_TOPICS = (
    "提醒用户注意脚下和周围的车辆行人。",
    "问用户要不要喝口水。",
)


def _on_foot(
    name: str,
    label: str,
    activity: str,
    prompt: str,
    topics: tuple[str, ...],
    spoken: tuple[str, ...],
):
    return ActivityProfile(
        name=name,
        label=label,
        activity_types=(activity,),
        spoken_names=spoken,
        mode=Mode.COMPANION,
        metrics=METRICS,
        phases=(Phase("active", f"{label}中", after_s=0),),
        split_m=1000.0,
        split_label="公里",
        split_facts=_split_facts,
        rules=(HR_EMERGENCY_RULE,),
        cadence=CADENCE,
        prompt=prompt,
        companion_topics=topics,
        default_targets=_defaults,
        start_hint="轻松地打个招呼，说你会一路陪着聊天，想安静随时说。",
        end_hint="用一句话轻松地总结，提醒喝点水，再问用户这次走下来感觉怎么样。",
        moving=_walking,
    )


WALKING = _on_foot(
    "walking",
    "散步",
    "walking",
    """\
当前运动是散步，你是陪伴模式：以自由聊天为主，像朋友一样边走边聊。
- 几乎不纠正，不催用户走快；偶尔顺口提一下走了多远、多久。
- 配速读作"每公里几分几秒"；距离超过一千米读成公里。
- 关心安全：过马路、天黑、身体不适时提醒一句。
""",
    (
        "随便和用户聊聊今天过得怎么样。",
        "问问用户周围的风景或者天气。",
        *SAFETY_TOPICS,
        "陪用户聊一个轻松的话题，比如最近吃了什么好吃的。",
    ),
    ("散步", "走路", "走走", "步行", "遛弯"),
)

HIKING = _on_foot(
    "hiking",
    "徒步",
    "hiking",
    """\
当前运动是徒步，你是陪伴模式：以自由聊天为主，陪用户走山路。
- 几乎不纠正；上坡时提醒放慢、小步走，下坡提醒注意膝盖和脚下。
- 可以提海拔（工具里的 alt_m，读作"海拔多少米"），距离超过一千米读成公里。
- 关心安全：补水、补能量、天气变化、天黑前下山。
""",
    (
        "问用户现在走到哪儿了，风景怎么样。",
        *SAFETY_TOPICS,
        "提醒用户上坡放慢、小步走，调整呼吸。",
        "问用户累不累，要不要找个地方歇一下。",
    ),
    ("徒步", "爬山"),
)
