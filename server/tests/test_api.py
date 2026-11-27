import base64
import hashlib
import json
import time
import uuid
from datetime import timedelta

import pytest
from fastapi.testclient import TestClient
from livekit import api

from coachw.api.app import create_app
from coachw.api.config import ApiSettings
from coachw.session import AGENT_NAME, SessionMeta

KEY, SECRET = "testkey", "testsecret-testsecret-testsecret-0"
ALICE = "alice-invite-01"
BOB = "bob-invite-0002"
ATHLETE = str(uuid.uuid4())

ENV = {
    "LIVEKIT_API_KEY": KEY,
    "LIVEKIT_API_SECRET": SECRET,
    "LIVEKIT_URL": "ws://livekit:7880",
    "LIVEKIT_PUBLIC_URL": "wss://coach.example.com",
    "COACHW_INVITES": f"{ALICE}:Alice:30,{BOB}:Bob:1",
    "COACHW_SESSION_MAX_MINUTES": "20",
    "COACHW_TOKEN_TTL_S": "600",
}


class Clock:
    def __init__(self) -> None:
        # Noon in Asia/Shanghai today, so adding minutes never crosses the quota day boundary
        day = time.time() // 86400 * 86400
        self.now = day + 4 * 3600

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def clock() -> Clock:
    return Clock()


class Coaches:
    """Rooms that have a coach in them, as LiveKit would report."""

    def __init__(self) -> None:
        self.gone: set[str] = set()

    async def __call__(self, room: str) -> bool:
        return room not in self.gone


@pytest.fixture
def coaches() -> Coaches:
    return Coaches()


@pytest.fixture
def client(clock: Clock, coaches: Coaches) -> TestClient:
    return TestClient(create_app(ApiSettings.from_env(ENV), clock=clock, has_coach=coaches))


def start(client: TestClient, code: str = ALICE, athlete: str = ATHLETE):
    return client.post("/v1/session", json={"invite_code": code, "athlete_id": athlete})


def verify(token: str) -> api.access_token.Claims:
    return api.TokenVerifier(KEY, SECRET).verify(token)


def webhook(client: TestClient, event: str, room: str, identity: str):
    body = json.dumps(
        {"event": event, "room": {"name": room}, "participant": {"identity": identity}}
    )
    auth = (
        api.AccessToken(KEY, SECRET)
        .with_sha256(base64.b64encode(hashlib.sha256(body.encode()).digest()).decode())
        .to_jwt()
    )
    return client.post(
        "/livekit/webhook",
        content=body,
        headers={"Authorization": auth, "Content-Type": "application/webhook+json"},
    )


def test_valid_invite_gets_scoped_token(client: TestClient, clock: Clock):
    r = start(client)
    assert r.status_code == 200
    body = r.json()
    assert body["server_url"] == "wss://coach.example.com"
    assert body["max_session_s"] == 20 * 60

    claims = verify(body["token"])
    assert claims.identity == ATHLETE
    assert claims.video.room == body["room"]
    assert claims.video.room_join
    assert claims.video.can_publish_data
    assert not claims.video.room_create
    assert not claims.video.room_admin
    assert [a.agent_name for a in claims.room_config.agents] == [AGENT_NAME]
    # the coach and its conversation outlive a phone reconnecting on mobile data
    assert claims.room_config.departure_timeout >= 90
    assert SessionMeta.from_json(claims.metadata) == SessionMeta(ATHLETE, 20 * 60)
    # names stay on the server
    assert "Alice" not in json.dumps(body) and "Alice" not in claims.metadata

    payload = json.loads(base64.urlsafe_b64decode(body["token"].split(".")[1] + "=="))
    assert payload["exp"] - time.time() == pytest.approx(600, abs=2)  # signed with real time


def test_an_athlete_keeps_one_room_until_livekit_finishes_it(client: TestClient):
    first = start(client).json()["room"]
    assert start(client).json()["room"] == first  # a reconnect lands with the same coach
    assert start(client, athlete=other_athlete()).json()["room"] != first
    webhook(client, "room_finished", first, "")
    second = start(client).json()["room"]
    assert second != first


def test_a_room_whose_coach_left_is_not_reused(client: TestClient, coaches: Coaches):
    first = start(client).json()["room"]
    coaches.gone.add(first)  # nobody would ever answer in it again
    assert start(client).json()["room"] != first


def test_token_expires_quickly(client: TestClient):
    token = start(client).json()["token"]
    payload = json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
    assert timedelta(seconds=payload["exp"] - payload["nbf"]) <= timedelta(minutes=10)


@pytest.mark.parametrize("code", ["", "nope-nope-nope", ALICE.upper()])
def test_unknown_invite_rejected(client: TestClient, code: str):
    assert start(client, code=code).status_code == 401


def test_athlete_id_must_be_uuid(client: TestClient):
    assert start(client, athlete="me").status_code == 422


def other_athlete() -> str:
    return str(uuid.uuid4())


def test_daily_minutes_enforced(client: TestClient):
    # Alice: 30 min/day, sessions capped at 20 min; one invite shared by two phones
    first = start(client).json()
    assert first["max_session_s"] == 20 * 60
    second = start(client, athlete=other_athlete()).json()
    assert second["max_session_s"] == 10 * 60  # what is left of the day
    assert start(client, athlete=other_athlete()).status_code == 429


def test_unused_tokens_release_minutes(client: TestClient, clock: Clock):
    start(client)
    start(client, athlete=other_athlete())
    assert start(client, athlete=other_athlete()).status_code == 429
    clock.now += 601
    assert start(client, athlete=other_athlete()).status_code == 200


def test_reconnect_is_not_blocked_by_the_dropped_session(client: TestClient, clock: Clock):
    first = start(client).json()
    webhook(client, "participant_joined", first["room"], ATHLETE)
    clock.now += 2 * 60
    # the link dropped; LiveKit has not noticed yet, so the first session is still "in the room"
    second = start(client).json()
    assert second["room"] == first["room"]
    assert second["max_session_s"] == 20 * 60  # 2 of 30 minutes spent, not the 20 reserved
    clock.now += 30
    # the rejoin can reach LiveKit before it lets go of the dropped connection
    webhook(client, "participant_joined", second["room"], ATHLETE)
    webhook(client, "participant_left", first["room"], ATHLETE)
    # another phone on the invite sees one session still in the room with its 20-minute cap
    third = start(client, athlete=other_athlete()).json()
    assert third["max_session_s"] == 10 * 60
    clock.now += 25 * 60
    webhook(client, "participant_left", second["room"], ATHLETE)
    # 27.5 minutes in the room, counted once
    assert start(client, athlete=other_athlete()).json()["max_session_s"] == 150


def test_retries_without_joining_do_not_use_up_the_day(client: TestClient):
    # Bob: 1 min/day; a phone whose joins keep failing asks again and again
    for _ in range(3):
        assert start(client, code=BOB).json()["max_session_s"] == 60


def test_webhooks_settle_real_usage(client: TestClient, clock: Clock):
    first = start(client).json()
    assert webhook(client, "participant_joined", first["room"], ATHLETE).status_code == 204
    clock.now += 25 * 60
    assert webhook(client, "participant_left", first["room"], ATHLETE).status_code == 204
    # actual time (25 min) replaces the 20 min reservation; 5 of 30 minutes are left
    second = start(client).json()
    assert second["max_session_s"] == 5 * 60


def test_short_remainder_is_rejected(client: TestClient):
    # Bob: 1 min/day; one reservation uses it all
    assert start(client, code=BOB).json()["max_session_s"] == 60
    assert start(client, code=BOB, athlete=other_athlete()).status_code == 429


def test_webhook_requires_signature(client: TestClient):
    r = client.post(
        "/livekit/webhook",
        content='{"event":"participant_left"}',
        headers={"Authorization": "bogus"},
    )
    assert r.status_code == 401


def test_settings_require_invites():
    with pytest.raises(ValueError, match="COACHW_INVITES"):
        ApiSettings.from_env(ENV | {"COACHW_INVITES": ""})


def test_the_phone_picks_a_cue_writer_the_server_offers(client: TestClient):
    def writer(name: str) -> str:
        body = {"invite_code": ALICE, "athlete_id": ATHLETE, "cue_writer": name}
        token = client.post("/v1/session", json=body).json()["token"]
        return SessionMeta.from_json(verify(token).metadata).cue_writer

    assert writer("qwen3.8-flash") == "qwen3.8-flash"
    assert writer("gpt-9") == ""  # not offered: the realtime model speaks alone
    assert SessionMeta.from_json(verify(start(client).json()["token"]).metadata).cue_writer == ""


def test_reused_room_clamps_max_session_when_quota_already_spent(client: TestClient, clock: Clock):
    first = start(client, code=BOB).json()
    webhook(client, "participant_joined", first["room"], ATHLETE)
    clock.now += 90  # Bob has 60 s/day; room stayed open past it
    rejoined = start(client, code=BOB).json()
    assert rejoined["room"] == first["room"]
    assert rejoined["max_session_s"] == 0


def test_dead_room_is_removed_after_coach_check_fails(clock: Clock):
    checks: list[str] = []

    async def no_coach(room: str) -> bool:
        checks.append(room)
        return False

    c = TestClient(create_app(ApiSettings.from_env(ENV), clock=clock, has_coach=no_coach))
    first = start(c, code=BOB).json()
    webhook(c, "participant_joined", first["room"], ATHLETE)
    clock.now += 70  # Bob's 60 s daily quota is now spent
    webhook(c, "participant_left", first["room"], ATHLETE)
    # coach left and quota is gone -> 429, and the dead room mapping is dropped
    assert start(c, code=BOB).status_code == 429
    assert checks == [first["room"]]
    # subsequent request must not probe the already-dead room again
    assert start(c, code=BOB).status_code == 429
    assert checks == [first["room"]]


def test_room_finished_webhook_settles_quota_without_participant_left(
    client: TestClient, clock: Clock
):
    first = start(client).json()  # Alice: 30 min/day, 20 min/session
    assert webhook(client, "participant_joined", first["room"], ATHLETE).status_code == 204
    clock.now += 5 * 60
    # participant_left missed; room_finished settles the 5 min and frees the remaining 25 min
    assert webhook(client, "room_finished", first["room"], "").status_code == 204
    second = start(client, athlete=other_athlete()).json()
    assert second["room"] != first["room"]
    assert second["max_session_s"] == 20 * 60


def test_rejoin_window_prevents_parallel_overspend(client: TestClient, clock: Clock):
    # Bob: 1 min/day; athlete joins, leaves after 10s, then reuses the still-live room
    first = start(client, code=BOB).json()
    webhook(client, "participant_joined", first["room"], ATHLETE)
    clock.now += 10
    webhook(client, "participant_left", first["room"], ATHLETE)
    rejoined = start(client, code=BOB).json()
    assert rejoined["room"] == first["room"]
    # While the first athlete is rejoining that room, another athlete on Bob's code cannot overspend
    assert start(client, code=BOB, athlete=other_athlete()).status_code == 429


def test_providers_endpoint_requires_invite_and_reports_configured(clock: Clock, coaches: Coaches):
    env = ENV | {"DASHSCOPE_API_KEY": "d-key", "OPENROUTER_API_KEY": "or-key"}
    c = TestClient(create_app(ApiSettings.from_env(env), clock=clock, has_coach=coaches))
    assert c.post("/v1/providers", json={"invite_code": "wrong"}).status_code == 401

    r = c.post("/v1/providers", json={"invite_code": ALICE})
    assert r.status_code == 200
    body = r.json()
    assert body["default_provider"] == "qwen"
    by_id = {p["id"]: p for p in body["providers"]}
    assert by_id["qwen"]["configured"] is True
    assert by_id["openrouter"]["configured"] is True
    assert by_id["openai"]["configured"] is False
    assert by_id["openai"]["missing_env"] == "OPENAI_API_KEY"
    # Never leak actual key values
    assert "d-key" not in json.dumps(body) and "or-key" not in json.dumps(body)


def test_phone_switches_voice_provider_and_gets_fresh_room(clock: Clock, coaches: Coaches):
    env = ENV | {"DASHSCOPE_API_KEY": "d-key", "OPENROUTER_API_KEY": "or-key"}
    c = TestClient(create_app(ApiSettings.from_env(env), clock=clock, has_coach=coaches))

    # Unknown provider -> 422; unconfigured provider -> 400 naming the missing env var
    bad = c.post(
        "/v1/session",
        json={"invite_code": ALICE, "athlete_id": ATHLETE, "voice_provider": "bogus"},
    )
    assert bad.status_code == 422
    missing = c.post(
        "/v1/session",
        json={"invite_code": ALICE, "athlete_id": ATHLETE, "voice_provider": "openai"},
    )
    assert missing.status_code == 400
    assert "OPENAI_API_KEY" in missing.json()["detail"]

    # Start on default (qwen), then switch to openrouter -> must not reuse the qwen room
    first = c.post("/v1/session", json={"invite_code": ALICE, "athlete_id": ATHLETE}).json()
    assert SessionMeta.from_json(verify(first["token"]).metadata).voice_provider == ""

    switched = c.post(
        "/v1/session",
        json={"invite_code": ALICE, "athlete_id": ATHLETE, "voice_provider": "openrouter"},
    ).json()
    assert switched["room"] != first["room"]
    assert SessionMeta.from_json(verify(switched["token"]).metadata).voice_provider == "openrouter"

    # Reconnecting with the same provider reuses the openrouter room
    again = c.post(
        "/v1/session",
        json={"invite_code": ALICE, "athlete_id": ATHLETE, "voice_provider": "openrouter"},
    ).json()
    assert again["room"] == switched["room"]
