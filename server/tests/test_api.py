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


@pytest.fixture
def client(clock: Clock) -> TestClient:
    return TestClient(create_app(ApiSettings.from_env(ENV), clock=clock))


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
    assert SessionMeta.from_json(claims.metadata) == SessionMeta(ATHLETE, 20 * 60)
    # names stay on the server
    assert "Alice" not in json.dumps(body) and "Alice" not in claims.metadata

    payload = json.loads(base64.urlsafe_b64decode(body["token"].split(".")[1] + "=="))
    assert payload["exp"] - time.time() == pytest.approx(600, abs=2)  # signed with real time


def test_every_session_gets_its_own_room(client: TestClient):
    assert start(client).json()["room"] != start(client).json()["room"]


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
    assert second["max_session_s"] == 20 * 60  # 2 of 30 minutes spent, not the 20 reserved
    clock.now += 30
    webhook(client, "participant_left", first["room"], ATHLETE)
    webhook(client, "participant_joined", second["room"], ATHLETE)
    # another phone on the invite sees both: 2.5 minutes spent and a 20-minute reservation
    third = start(client, athlete=other_athlete()).json()
    assert third["max_session_s"] == 7 * 60 + 30


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
