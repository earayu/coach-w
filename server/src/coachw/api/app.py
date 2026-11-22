"""Token API: invite code -> short-lived LiveKit token for one coach session (spec 3.1)."""

from __future__ import annotations

import logging
import time
from collections.abc import Awaitable, Callable
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
    # developer setting: text model that writes the coach's cues; "" = realtime model only
    cue_writer: str = ""


class SessionResponse(BaseModel):
    server_url: str
    room: str
    token: str
    token_expires_at: datetime
    max_session_s: int


CoachCheck = Callable[[str], Awaitable[bool]]


def livekit_coach_check(settings: ApiSettings) -> CoachCheck:
    """Whether a coach is in the room right now. A room whose coach has left (its session ended,
    the agent restarted) gets no new one dispatched on rejoin: such a room is not reused."""

    async def has_coach(room: str) -> bool:
        lk = api.LiveKitAPI(
            settings.livekit_url.replace("ws", "http", 1),
            settings.livekit_api_key,
            settings.livekit_api_secret,
        )
        try:
            found = await lk.room.list_participants(api.ListParticipantsRequest(room=room))
        except Exception as e:  # unknown room, LiveKit unreachable: start over in a new room
            logger.info("room %s not reusable: %s", room, type(e).__name__)
            return False
        finally:
            await lk.aclose()
        return any(p.kind == api.ParticipantInfo.AGENT for p in found.participants)

    return has_coach


def create_app(
    settings: ApiSettings,
    clock: Callable[[], float] = time.time,
    has_coach: CoachCheck | None = None,
) -> FastAPI:
    app = FastAPI(title="coach-w token API", docs_url=None, redoc_url=None)
    has_coach = has_coach or livekit_coach_check(settings)
    ledger = MinuteLedger(settings.quota_tz)
    # One room per athlete until LiveKit finishes it: a phone that reconnects (its own retry, a
    # fresh token) lands back with the same coach and conversation instead of a new one (COCH-15).
    rooms: dict[tuple[str, str], str] = {}
    webhooks = api.WebhookReceiver(
        api.TokenVerifier(settings.livekit_api_key, settings.livekit_api_secret)
    )

    @app.get("/healthz")
    def healthz() -> dict:
        return {"ok": True}

    # async on purpose: FastAPI runs plain `def` handlers in a thread pool, where parallel requests
    # and the webhook would read and replace the ledger at the same time. Nothing here blocks.
    @app.post("/v1/session")
    async def create_session(req: SessionRequest) -> SessionResponse:
        try:
            athlete_id = parse_athlete_id(req.athlete_id)
        except ValueError:
            raise HTTPException(422, "athlete_id must be a UUID") from None
        invite = settings.invites.find(req.invite_code)
        if invite is None:
            logger.info("rejected: unknown invite code athlete_id=%s", athlete_id)
            raise HTTPException(401, "unknown invite code")

        now = clock()
        key = (invite.code, athlete_id)
        ledger.supersede(invite.code, athlete_id)
        remaining = invite.daily_minutes * 60 - ledger.used_s(invite.code, now)
        room = rooms.get(key)
        reused = (
            room is not None
            and await has_coach(room)
            and ledger.reuse(room, invite.code, athlete_id, now, settings.token_ttl_s)
        )
        if not reused and remaining < settings.min_session_s:
            logger.info("rejected: daily minutes used up athlete_id=%s", athlete_id)
            raise HTTPException(429, "daily voice minutes used up")

        # a live room's coach keeps the cap it started with; this one applies if it restarts
        writer = req.cue_writer.strip()
        if writer and writer not in settings.writer_models:
            logger.info("unknown cue writer ignored athlete_id=%s", athlete_id)
            writer = ""
        meta = SessionMeta(athlete_id, int(min(remaining, settings.session_max_s)), writer)
        issued = issue_token(
            api_key=settings.livekit_api_key,
            api_secret=settings.livekit_api_secret,
            meta=meta,
            room=room if reused and room else new_room_name(),
            ttl_s=settings.token_ttl_s,
        )
        if not reused:
            ledger.reserve(
                invite.code,
                issued.room,
                issued.identity,
                meta.max_session_s,
                now,
                settings.token_ttl_s,
            )
            rooms[key] = issued.room
        logger.info(
            "issued athlete_id=%s room=%s max_session_s=%d reused=%s",
            athlete_id,
            issued.room,
            meta.max_session_s,
            reused,
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
        elif event.event == "room_finished":
            for key in [k for k, room in rooms.items() if room == event.room.name]:
                del rooms[key]

    return app
