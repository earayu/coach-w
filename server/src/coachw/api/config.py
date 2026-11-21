from __future__ import annotations

import os
from collections.abc import Mapping
from dataclasses import dataclass
from zoneinfo import ZoneInfo

from coachw.api.invites import InviteBook


@dataclass(frozen=True, slots=True)
class ApiSettings:
    livekit_api_key: str
    livekit_api_secret: str
    # URL the phone connects to; in production wss://<domain> behind Caddy
    livekit_public_url: str
    invites: InviteBook
    session_max_s: int
    min_session_s: int
    token_ttl_s: int
    quota_tz: ZoneInfo

    @classmethod
    def from_env(cls, env: Mapping[str, str] = os.environ) -> ApiSettings:
        def need(name: str) -> str:
            if not (value := env.get(name, "").strip()):
                raise ValueError(f"{name} is required")
            return value

        invites = InviteBook.parse(env.get("COACHW_INVITES", ""))
        if not len(invites):
            raise ValueError("COACHW_INVITES is empty: nobody could get a token")
        return cls(
            livekit_api_key=need("LIVEKIT_API_KEY"),
            livekit_api_secret=need("LIVEKIT_API_SECRET"),
            livekit_public_url=env.get("LIVEKIT_PUBLIC_URL") or need("LIVEKIT_URL"),
            invites=invites,
            session_max_s=int(env.get("COACHW_SESSION_MAX_MINUTES", "60")) * 60,
            min_session_s=int(env.get("COACHW_MIN_SESSION_S", "60")),
            token_ttl_s=int(env.get("COACHW_TOKEN_TTL_S", "600")),
            quota_tz=ZoneInfo(env.get("COACHW_QUOTA_TZ", "Asia/Shanghai")),
        )
