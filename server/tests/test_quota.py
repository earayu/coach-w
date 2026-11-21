from datetime import datetime
from zoneinfo import ZoneInfo

from coachw.api.quota import MinuteLedger

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
