from datetime import datetime
from zoneinfo import ZoneInfo

from coachw.api.quota import MinuteLedger, SessionState

TZ = ZoneInfo("Asia/Shanghai")
T0 = datetime(2026, 11, 21, 8, 0, tzinfo=TZ).timestamp()


def ledger() -> MinuteLedger:
    return MinuteLedger(TZ)


def test_reservation_counts_until_join_window_closes():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    assert q.used_s("k", T0 + 10) == 600
    assert q.used_s("k", T0 + 301) == 0


def test_settles_to_actual_time_in_room():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    q.joined("r1", "a", T0 + 5)
    assert q.used_s("k", T0 + 100) == 600  # still in the room: full cap reserved
    q.left("r1", "a", T0 + 125)
    assert q.used_s("k", T0 + 1000) == 120


def test_rejoin_accumulates():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    q.joined("r1", "a", T0)
    q.left("r1", "a", T0 + 60)
    q.joined("r1", "a", T0 + 100)
    q.left("r1", "a", T0 + 130)
    assert q.used_s("k", T0 + 200) == 90


def test_ignores_other_participants_and_rooms():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    q.joined("r1", "agent-xyz", T0)
    q.joined("other-room", "a", T0)
    q.left("r1", "agent-xyz", T0 + 10)
    assert q.used_s("k", T0 + 301) == 0


def test_keys_are_separate():
    q = ledger()
    q.reserve("k1", "r1", "a", 600, T0, join_window_s=300)
    q.reserve("k2", "r2", "b", 300, T0, join_window_s=300)
    assert q.used_s("k1", T0) == 600
    assert q.used_s("k2", T0) == 300


def test_new_day_starts_from_zero_in_quota_timezone():
    q = ledger()
    late = datetime(2026, 11, 21, 23, 30, tzinfo=TZ).timestamp()
    q.reserve("k", "r1", "a", 600, late, join_window_s=300)
    q.joined("r1", "a", late)
    q.left("r1", "a", late + 600)
    assert q.used_s("k", late + 601) == 600
    next_morning = datetime(2026, 11, 22, 0, 30, tzinfo=TZ).timestamp()
    assert q.used_s("k", next_morning) == 0


def test_reuse_after_leave_holds_reservation_during_rejoin_window():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    assert q.state_of("r1") is SessionState.RESERVED
    q.joined("r1", "a", T0)
    assert q.state_of("r1") is SessionState.ACTIVE
    q.left("r1", "a", T0 + 60)
    assert q.state_of("r1") is SessionState.SETTLED
    assert q.used_s("k", T0 + 65) == 60

    # Athlete reuses the live room: reservation must hold again while rejoining so parallel
    # requests on the same invite cannot overspend.
    assert q.reuse("r1", "k", "a", T0 + 65, join_window_s=300)
    assert q.state_of("r1") is SessionState.REJOINING
    assert q.used_s("k", T0 + 100) == 600

    # If the rejoin window expires without joining, usage settles back to actual time spent.
    assert q.used_s("k", T0 + 400) == 60


def test_supersede_clears_rejoining_reservation_for_retry():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    q.joined("r1", "a", T0)
    q.left("r1", "a", T0 + 60)
    assert q.reuse("r1", "k", "a", T0 + 65, join_window_s=300)
    assert q.state_of("r1") is SessionState.REJOINING
    q.supersede("k", "a")
    assert q.state_of("r1") is SessionState.SETTLED
    assert q.used_s("k", T0 + 70) == 60


def test_room_finished_settles_active_session_and_is_terminal():
    q = ledger()
    q.reserve("k", "r1", "a", 600, T0, join_window_s=300)
    q.joined("r1", "a", T0)
    # participant_left webhook lost; room_finished must settle active time and close the room
    q.room_finished("r1", T0 + 90)
    assert q.state_of("r1") is SessionState.CLOSED
    assert q.used_s("k", T0 + 100) == 90

    # Closed is terminal: late joins, leaves, or reuse cannot resurrect it.
    assert not q.reuse("r1", "k", "a", T0 + 110, join_window_s=300)
    q.joined("r1", "a", T0 + 120)
    q.left("r1", "a", T0 + 200)
    assert q.state_of("r1") is SessionState.CLOSED
    assert q.used_s("k", T0 + 210) == 90


def test_active_session_counts_live_usage_past_reserved_cap():
    q = ledger()
    q.reserve("k", "r1", "a", 60, T0, join_window_s=300)
    q.joined("r1", "a", T0)
    assert q.used_s("k", T0 + 30) == 60
    assert q.used_s("k", T0 + 110) == 110
