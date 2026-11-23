import uuid

import pytest
from synth import T0_MS, Clock, Runner

from coachw.coach.brain import CoachBrain
from coachw.coach.director import GOAL_KEY
from coachw.profiles.base import Athlete
from coachw.profiles.running import HR_CEILING, HR_EMERGENCY, TARGET_SPEED
from coachw.protocol import CoachCue, CuePriority, Haptic, WorkoutState


class Session:
    """A coach session driven by synthetic frames; collects every delivery."""

    def __init__(self, activity="running", max_hr=None):
        self.clock = Clock()
        self.brain = CoachBrain(
            Athlete(str(uuid.uuid4()), max_hr_bpm=max_hr),
            clock=self.clock,
            wall_ms=lambda: T0_MS + int(self.clock.now * 1000),
        )
        self.user_speaking = False
        self.agent_speaking = False
        self.deliveries = []
        self.run = Runner(self.brain.on_frame, self.clock, activity=activity, on_tick=self.tick)

    def tick(self):
        d = self.brain.tick(user_speaking=self.user_speaking, agent_speaking=self.agent_speaking)
        if d:
            self.deliveries.append(d)

    def kinds(self):
        return [d.cue.event.kind for d in self.deliveries]


def test_profile_is_loaded_from_the_activity():
    s = Session()
    assert (
        s.brain.profile is None and s.brain.tick(user_speaking=False, agent_speaking=False) is None
    )
    s.run.run(1)
    assert s.brain.profile.name == "running"
    assert s.brain.targets[HR_CEILING] == 171 and s.brain.targets[HR_EMERGENCY] == 184


def test_athlete_max_hr_drives_the_targets():
    s = Session(max_hr=200)
    s.run.run(1)
    assert s.brain.targets[HR_CEILING] == 180 and s.brain.targets[HR_EMERGENCY] == 194


def test_unknown_activity_gets_the_fallback():
    s = Session(activity="yoga")
    s.run.run(5)
    assert s.brain.profile.name == "fallback"
    assert s.brain.profile.activity_types == ("yoga",)
    assert s.brain.profile_version == 1


def test_new_activity_starts_a_fresh_state():
    s = Session()
    s.run.run(30)
    s.brain.set_quiet(5)
    s.run.activity = "yoga"
    s.run.run(1)
    assert s.brain.profile.name == "fallback"
    assert s.brain.profile_version == 2
    assert s.brain.state.elapsed_s == s.run.elapsed
    assert s.brain.queue.is_quiet(s.clock.now)


def test_a_steady_run_gets_milestones_and_companion_but_no_alerts():
    s = Session()
    s.run.run(30 * 60, speed=1000 / 330, hr=150, cadence=172)  # ~5.45 km at 5'30"
    kinds = s.kinds()
    assert kinds[0] == "start"
    assert [k for k in kinds if k.startswith("split:")] == [f"split:{i}" for i in range(1, 6)]
    assert "phase:main" in kinds
    assert "companion" in kinds
    priorities = {d.cue.priority for d in s.deliveries}
    assert CuePriority.EMERGENCY not in priorities and CuePriority.CORRECTION not in priorities


def test_heart_rate_emergency_reaches_the_watch():
    s = Session()
    s.run.run(120, hr=150)
    s.run.run(30, hr=188)
    [d] = [d for d in s.deliveries if d.cue.event.kind == "hr_emergency"]
    assert d.cue.priority is CuePriority.EMERGENCY
    assert "188" in d.instructions and "184" in d.instructions
    assert "常识" not in d.instructions  # safety first, no second thoughts
    cue = d.watch
    assert isinstance(cue, CoachCue)
    assert cue.haptic is Haptic.FAILURE and cue.text == "心率过高"
    assert cue.expires_at - cue.ts == pytest.approx(15_000, abs=1000)
    assert CoachCue.from_json(cue.to_json()) == cue
    # the lesser heart-rate alert does not repeat what the emergency said
    assert "hr_ceiling" not in s.kinds()


def test_emergency_interrupts_the_coach():
    s = Session()
    s.run.run(120, hr=150)
    s.agent_speaking = True
    s.run.run(30, hr=188)
    [d] = s.deliveries[-1:]
    assert d.cue.event.kind == "hr_emergency" and d.interrupt


def test_missing_heart_rate_never_alerts():
    s = Session()
    s.run.run(20 * 60, speed=1000 / 330, hr=None, cadence=None)
    assert not [k for k in s.kinds() if k.startswith(("hr_", "cadence", "gct"))]
    assert "hr_bpm" not in s.brain.get_metrics()


def test_companion_chat_never_buzzes_the_watch():
    s = Session()
    s.run.run(15 * 60)
    for d in s.deliveries:
        if d.cue.priority is CuePriority.COMPANION:
            assert d.watch is None


def test_quiet_mode_mutes_all_but_emergencies():
    s = Session()
    s.run.run(5)
    s.brain.set_quiet(30)
    before = len(s.deliveries)
    s.run.run(20 * 60, speed=1000 / 300, hr=150)
    assert len(s.deliveries) == before
    s.run.run(30, hr=190)
    assert s.kinds()[-1] == "hr_emergency"


def test_user_speaking_holds_cues_until_they_expire():
    s = Session()
    s.user_speaking = True
    s.run.run(60)
    assert s.deliveries == []
    assert s.brain.queue.dropped_expired >= 1
    s.user_speaking = False
    s.run.run(5)
    assert "start" not in s.kinds()  # stale by now: never played late


def test_target_pace_tool_drives_pace_rules():
    s = Session()
    s.run.run(5)
    result = s.brain.run_profile_tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 30})
    assert result == {"ok": True, "target_pace_per_km": "5'30\"", "goal_distance_m": None}
    assert s.brain.targets[TARGET_SPEED] == pytest.approx(1000 / 330)
    s.run.run(11 * 60, speed=1000 / 360)  # 30 s/km slow, past warm-up
    slow = [d for d in s.deliveries if d.cue.event.kind == "pace_slow"]
    assert len(slow) == 1
    assert slow[0].watch.haptic is Haptic.DIRECTION_UP


def test_adjust_target_pace_validation_and_goal():
    s = Session()
    s.run.run(1)
    tool = s.brain.run_profile_tool
    assert tool("adjust_target_pace", {"pace_min": 1, "pace_sec": 0})["ok"] is False
    assert tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 75})["ok"] is False
    assert tool("adjust_target_pace", {"pace_min": "x", "pace_sec": 0})["ok"] is False
    assert tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 0, "goal_km": 500})["ok"] is False
    r = tool("adjust_target_pace", {"pace_min": 6, "pace_sec": 0, "goal_km": 5})
    assert r["goal_distance_m"] == 5000 and s.brain.targets[GOAL_KEY] == 5000
    r = tool("adjust_target_pace", {"pace_min": 0, "pace_sec": 0, "goal_km": 0})
    assert r["target_pace_per_km"] is None
    assert TARGET_SPEED not in s.brain.targets and GOAL_KEY not in s.brain.targets
    assert tool("no_such_tool", {})["ok"] is False


def test_profile_tool_before_any_workout():
    s = Session()
    assert s.brain.run_profile_tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 0}) == {
        "ok": False,
        "reason": "no workout running yet",
    }


def test_progress_and_summary_tools():
    s = Session()
    assert s.brain.get_progress()["available"] is False
    assert s.brain.end_workout_summary()["available"] is False
    s.run.run(5)
    s.brain.run_profile_tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 0, "goal_km": 3})
    s.run.run(700, speed=1000 / 300, hr=150)
    p = s.brain.get_progress()
    assert p["phase"] == "主训练"
    assert p["distance_m"] == pytest.approx(15 + 700 * 1000 / 300, abs=1)
    assert p["remaining_m"] == pytest.approx(3000 - p["distance_m"], abs=0.2)
    assert [x["index"] for x in p["splits"]] == [1, 2]
    assert p["splits"][0]["duration_s"] == pytest.approx(300, abs=1)
    s.run.run(2, state=WorkoutState.ENDED)
    summary = s.brain.end_workout_summary()
    assert summary["state"] == "ended"
    assert summary["avg_hr_bpm"] == pytest.approx(150)
    assert summary["avg_speed_mps_spoken"] == "每公里 5 分 0 秒"
    assert summary["fastest_split"] in (1, 2)
    assert s.brain.phase_label() == "结束"


def test_set_quiet_is_clamped():
    s = Session()
    assert s.brain.set_quiet(120)["minutes"] == 30
    assert s.brain.set_quiet(-3)["quiet"] is False


def test_status_summary_carries_the_live_readings():
    # COCH-18: the coach answered "what's my heart rate" without looking; it now always sees it
    s = Session()
    assert s.brain.status_summary() is None
    s.run.run(5)
    s.brain.run_profile_tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 30, "goal_km": 5})
    s.run.run(700, speed=1000 / 330, hr=163)
    text = s.brain.status_summary()
    assert text.startswith("【运动状态")
    # COCH-19: as a user item right before the athlete's turn it was read out unasked
    assert "用户没问就不要念" in text
    assert "主训练" in text
    assert "手表此刻的实时数据：心率 163，配速 每公里 5 分 30 秒" in text
    s.run.run(30, hr=171)
    assert "心率 171" in s.brain.status_summary()


def test_status_summary_says_when_there_are_no_live_readings():
    s = Session()
    s.run.run(60, hr=150)
    s.clock.advance(30)
    text = s.brain.status_summary()
    assert "手表此刻没有心率等实时数据" in text and "150" not in text


def test_sessions_are_isolated_per_athlete():
    a, b = Session(), Session()
    a.run.run(120, hr=150)
    a.run.run(30, hr=190)
    b.run.run(150, hr=140)
    assert "hr_emergency" in a.kinds() and "hr_emergency" not in b.kinds()
    assert a.brain.athlete.athlete_id != b.brain.athlete.athlete_id


def test_end_milestone_on_workout_end():
    s = Session()
    s.run.run(90)
    s.run.run(3, state=WorkoutState.ENDED)
    assert s.kinds()[-1] == "end"
    assert s.deliveries[-1].watch.haptic is Haptic.STOP


def companions(s):
    return [d for d in s.deliveries if d.cue.priority is CuePriority.COMPANION]


def test_companion_chat_waits_its_interval_after_a_conversation():
    s = Session()
    slow = 1.5  # splits far apart, so only companion chat fills the gaps
    s.run.run(200, speed=slow)
    s.user_speaking = True  # the athlete and the coach chat for a while
    s.run.run(30, speed=slow)
    s.user_speaking = False
    talked_at = s.clock.now
    s.run.run(400, speed=slow)
    first = companions(s)[0]
    assert first.cue.created_at - talked_at >= s.brain.profile.cadence.companion_s


def test_rejected_target_pace_changes_nothing():
    s = Session()
    s.run.run(1)
    tool = s.brain.run_profile_tool
    tool("adjust_target_pace", {"pace_min": 5, "pace_sec": 30, "goal_km": 10})
    before = dict(s.brain.targets)
    assert tool("adjust_target_pace", {"pace_min": 6, "pace_sec": 0, "goal_km": 500})["ok"] is False
    assert tool("adjust_target_pace", {"pace_min": 0, "pace_sec": 0, "goal_km": -1})["ok"] is False
    assert tool("adjust_target_pace", {"pace_min": 1, "pace_sec": -60})["ok"] is False
    assert s.brain.targets == before


def test_the_next_workout_in_the_same_voice_session_starts_fresh():
    s = Session()
    s.run.run(400)
    s.run.run(2, state=WorkoutState.ENDED)
    s.run.new_workout()
    s.run.run(30)
    assert s.kinds().count("start") == 2
    assert s.brain.state.elapsed_s == 30 and s.brain.state.started
    assert s.brain.state.distance_m == pytest.approx(90)


def test_a_new_workout_is_noticed_even_when_the_end_frame_was_lost():
    s = Session()
    s.run.run(400)
    s.run.new_workout()
    s.run.run(30)
    assert s.kinds().count("start") == 2
    assert s.brain.state.elapsed_s == 30


def test_non_urgent_cues_ask_the_coach_to_sanity_check_the_numbers():
    s = Session()
    s.run.run(400, speed=1000 / 300)
    [split] = [d for d in s.deliveries if d.cue.event.kind.startswith("split")]
    assert "常识" in split.instructions and "跑步" in split.instructions
    assert "鼓励" not in split.instructions
