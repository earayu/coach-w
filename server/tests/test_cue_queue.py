from coachw.coach.cue_queue import CueQueue
from coachw.coach.events import CoachEvent
from coachw.protocol import CuePriority

E, C, M, P = (
    CuePriority.EMERGENCY,
    CuePriority.CORRECTION,
    CuePriority.MILESTONE,
    CuePriority.COMPANION,
)


def event(kind, priority=C, *, key=None, cooldown=60.0, ttl=20.0):
    return CoachEvent(kind, priority, kind, key or kind, cooldown, ttl)


def queue(max_per_minute=10, min_gap_s=0.0):
    return CueQueue(max_per_minute=max_per_minute, min_gap_s=min_gap_s)


def take(q, now, user=False, agent=False):
    r = q.next(now, user_speaking=user, agent_speaking=agent)
    return r and r.cue.event.kind


def test_priority_then_age():
    q = queue()
    q.offer(event("chat", P), 0)
    q.offer(event("km", M), 1)
    q.offer(event("hr", C), 2)
    q.offer(event("pace", C), 3)
    q.offer(event("danger", E), 4)
    assert [take(q, 5) for _ in range(6)] == ["danger", "hr", "pace", "km", "chat", None]


def test_cooldown_blocks_same_key():
    q = queue()
    q.offer(event("hr", cooldown=60), 0)
    assert take(q, 0) == "hr"
    assert q.offer(event("hr", cooldown=60), 30) is None
    assert q.offer(event("hr", cooldown=60), 61) is not None


def test_pending_key_is_not_duplicated_but_upgraded():
    q = queue()
    first = q.offer(event("hr_ceiling", C, key="hr"), 0)
    assert q.offer(event("hr_ceiling", C, key="hr"), 1) is None
    upgraded = q.offer(event("hr_emergency", E, key="hr"), 2)
    assert upgraded and upgraded.id != first.id
    assert [c.event.kind for c in q.pending] == ["hr_emergency"]


def test_less_urgent_release_does_not_hold_back_an_emergency():
    q = queue()
    q.offer(event("hr_ceiling", C, key="hr", cooldown=180), 0)
    assert take(q, 0) == "hr_ceiling"
    assert q.offer(event("hr_emergency", E, key="hr", cooldown=90), 10) is not None
    assert take(q, 10) == "hr_emergency"
    # and the emergency's release mutes the lesser alert for its cooldown
    assert q.offer(event("hr_ceiling", C, key="hr", cooldown=180), 20) is None


def test_expired_cues_are_dropped_not_played_late():
    q = queue()
    q.offer(event("km", M, ttl=10), 0)
    assert take(q, 5, user=True) is None
    assert take(q, 10) is None
    assert q.dropped_expired == 1


def test_no_talking_over_the_user():
    q = queue()
    q.offer(event("km", M), 0)
    assert take(q, 1, user=True) is None
    q.offer(event("danger", E), 1)
    assert take(q, 1, user=True) == "danger"
    assert take(q, 2) == "km"


def test_only_emergencies_cut_in_and_they_interrupt():
    q = queue()
    q.offer(event("km", M), 0)
    assert q.next(1, user_speaking=False, agent_speaking=True) is None
    q.offer(event("danger", E), 1)
    release = q.next(1, user_speaking=False, agent_speaking=True)
    assert release.cue.event.kind == "danger" and release.interrupt
    q.offer(event("danger2", E), 2)
    assert not q.next(2, user_speaking=False, agent_speaking=False).interrupt


def test_quiet_lets_only_emergencies_through():
    q = queue()
    q.offer(event("km", M), 0)
    q.set_quiet(300, 0)
    assert q.pending == []
    q.offer(event("chat", P), 1)
    assert take(q, 1) is None
    q.offer(event("danger", E), 2)
    assert take(q, 2) == "danger"
    assert q.is_quiet(299) and not q.is_quiet(300)
    q.offer(event("chat2", P), 301)
    assert take(q, 301) == "chat2"


def test_quiet_can_be_cancelled():
    q = queue()
    q.set_quiet(300, 0)
    q.set_quiet(0, 10)
    assert not q.is_quiet(11)
    assert q.quiet_remaining_s(11) == 0


def test_density_cap_per_minute_and_gap():
    q = queue(max_per_minute=2, min_gap_s=10)
    for i in range(4):
        q.offer(event(f"m{i}", M, ttl=120), 0)
    assert take(q, 0) == "m0"
    assert take(q, 5) is None  # gap
    assert take(q, 10) == "m1"
    assert take(q, 30) is None  # 2 in the last minute
    assert take(q, 60) == "m2"
    q.offer(event("danger", E), 61)
    assert take(q, 61) == "danger"  # emergencies are never rate limited


def test_release_bookkeeping():
    q = queue()
    q.offer(event("km", M), 0)
    take(q, 3)
    assert q.last_spoken_at == 3 and q.last_alert_at is None
    q.offer(event("hr", C), 4)
    take(q, 5)
    assert q.last_alert_at == 5
