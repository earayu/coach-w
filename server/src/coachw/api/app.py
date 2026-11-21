"""Token API: invite code -> short-lived LiveKit token for one coach session (spec 3.1)."""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from datetime import UTC, datetime

from fastapi import FastAPI, HTTPException, Request
from livekit import api
from pydantic import BaseModel

from coachw.api.config import ApiSettings
from coachw.api.quota import MinuteLedger
from coachw.api.tokens import issue_token, new_room_name
from coachw.session import SessionMeta, parse_athlete_id

# Only athlete_id and room are logged; never the invite code or the person's name (spec 11).
logger = logging.getLogger("coachw.api")


class SessionRequest(BaseModel):
    invite_code: str
    athlete_id: str


class SessionResponse(BaseModel):
    server_url: str
    room: str
    token: str
    token_expires_at: datetime
    max_session_s: int


def create_app(settings: ApiSettings, clock: Callable[[], float] = time.time) -> FastAPI:
    app = FastAPI(title="coach-w token API", docs_url=None, redoc_url=None)
    ledger = MinuteLedger(settings.quota_tz)
    webhooks = api.WebhookReceiver(
        api.TokenVerifier(settings.livekit_api_key, settings.livekit_api_secret)
    )

    @app.get("/healthz")
    def healthz() -> dict:
        return {"ok": True}

    @app.post("/v1/session")
    def create_session(req: SessionRequest) -> SessionResponse:
        try:
            athlete_id = parse_athlete_id(req.athlete_id)
        except ValueError:
            raise HTTPException(422, "athlete_id must be a UUID") from None
        invite = settings.invites.find(req.invite_code)
        if invite is None:
            logger.info("rejected: unknown invite code athlete_id=%s", athlete_id)
            raise HTTPException(401, "unknown invite code")

        now = clock()
        remaining = invite.daily_minutes * 60 - ledger.used_s(invite.code, now)
        if remaining < settings.min_session_s:
            logger.info("rejected: daily minutes used up athlete_id=%s", athlete_id)
            raise HTTPException(429, "daily voice minutes used up")

        meta = SessionMeta(athlete_id, int(min(remaining, settings.session_max_s)))
        issued = issue_token(
            api_key=settings.livekit_api_key,
            api_secret=settings.livekit_api_secret,
            meta=meta,
            room=new_room_name(),
            ttl_s=settings.token_ttl_s,
        )
        ledger.reserve(
            invite.code, issued.room, issued.identity, meta.max_session_s, now, settings.token_ttl_s
        )
        logger.info(
            "issued athlete_id=%s room=%s max_session_s=%d",
            athlete_id,
            issued.room,
            meta.max_session_s,
        )
        return SessionResponse(
            server_url=settings.livekit_public_url,
            room=issued.room,
            token=issued.token,
            token_expires_at=datetime.fromtimestamp(now + settings.token_ttl_s, UTC),
            max_session_s=meta.max_session_s,
        )

    @app.post("/livekit/webhook", status_code=204)
    async def livekit_webhook(request: Request) -> None:
        body = (await request.body()).decode()
        try:
            event = webhooks.receive(body, request.headers.get("Authorization", ""))
        except Exception:
            raise HTTPException(401, "invalid webhook signature") from None
        now = clock()
        if event.event == "participant_joined":
            ledger.joined(event.room.name, event.participant.identity, now)
        elif event.event == "participant_left":
            ledger.left(event.room.name, event.participant.identity, now)

    return app
