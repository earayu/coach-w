"""LiveKit join tokens for the athlete's room; the coach agent is dispatched by the token."""

from __future__ import annotations

import secrets
from dataclasses import dataclass
from datetime import timedelta

from livekit import api

from coachw.session import AGENT_NAME, SessionMeta


@dataclass(frozen=True, slots=True)
class IssuedToken:
    room: str
    identity: str
    token: str


DEPARTURE_TIMEOUT_S = 120


def new_room_name() -> str:
    return f"coach-{secrets.token_hex(8)}"


def issue_token(
    *,
    api_key: str,
    api_secret: str,
    meta: SessionMeta,
    room: str,
    ttl_s: int,
) -> IssuedToken:
    """Token that can only join `room`; joining creates the room and dispatches the coach.

    `ttl_s` bounds when the token can be used to join; how long the session lasts is bounded by
    `meta.max_session_s`, which the agent enforces.
    """
    identity = meta.athlete_id
    token = (
        api.AccessToken(api_key, api_secret)
        .with_identity(identity)
        .with_ttl(timedelta(seconds=ttl_s))
        .with_metadata(meta.to_json())
        .with_grants(
            api.VideoGrants(
                room_join=True,
                room=room,
                can_publish=True,
                can_subscribe=True,
                can_publish_data=True,
            )
        )
        .with_room_config(
            api.RoomConfiguration(
                agents=[api.RoomAgentDispatch(agent_name=AGENT_NAME)],
                max_participants=2,
                empty_timeout=60,
                # The phone drops off on mobile data and comes back after 30-90 s (COCH-15). With
                # LiveKit's default of 20 s the room, the coach and the whole conversation were
                # gone by then and a fresh coach greeted the athlete again.
                departure_timeout=DEPARTURE_TIMEOUT_S,
            )
        )
        .to_jwt()
    )
    return IssuedToken(room=room, identity=identity, token=token)
