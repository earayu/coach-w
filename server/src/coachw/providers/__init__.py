"""Voice provider registry (realtime WebSocket models and OpenRouter STT+LLM+TTS pipeline).

Vendor SDKs and plugins are imported only inside this package (AGENTS.md), so switching models
never touches coach code. Each provider reads its own settings from the environment.
"""

from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

if TYPE_CHECKING:
    from livekit.agents import AgentSession, llm

ProviderKind = Literal["realtime", "pipeline"]


@dataclass(frozen=True, slots=True)
class ProviderSpec:
    id: str
    title: str
    detail: str
    kind: ProviderKind
    env_keys: tuple[str, ...]


@dataclass(frozen=True, slots=True)
class ProviderStatus:
    id: str
    title: str
    detail: str
    kind: ProviderKind
    configured: bool
    missing_env: str = ""


PROVIDER_SPECS: tuple[ProviderSpec, ...] = (
    ProviderSpec(
        id="qwen",
        title="Qwen Realtime",
        detail="通义千问原生实时语音（DashScope）",
        kind="realtime",
        env_keys=("DASHSCOPE_API_KEY", "QWEN_API_KEY"),
    ),
    ProviderSpec(
        id="openrouter",
        title="OpenRouter 语音",
        detail="用 OpenRouter Key 跑 STT + LLM + TTS（OpenRouter 无 /v1/realtime）",
        kind="pipeline",
        env_keys=("OPENROUTER_API_KEY",),
    ),
    ProviderSpec(
        id="openai",
        title="OpenAI Realtime",
        detail="OpenAI 原生实时语音（支持自定义 Base URL）",
        kind="realtime",
        env_keys=("OPENAI_API_KEY",),
    ),
    ProviderSpec(
        id="gemini",
        title="Gemini Live",
        detail="Google 原生实时语音",
        kind="realtime",
        env_keys=("GOOGLE_API_KEY", "GEMINI_API_KEY"),
    ),
    ProviderSpec(
        id="xai",
        title="xAI Grok Voice",
        detail="Grok 原生实时语音",
        kind="realtime",
        env_keys=("XAI_API_KEY",),
    ),
)
PROVIDER_BY_ID: dict[str, ProviderSpec] = {spec.id: spec for spec in PROVIDER_SPECS}
DEFAULT_PROVIDER = "qwen"


def _qwen(env: Mapping[str, str]) -> llm.RealtimeModel:
    from coachw.providers.qwen import create_qwen_realtime

    return create_qwen_realtime(env)


def _openai(env: Mapping[str, str]) -> llm.RealtimeModel:
    from coachw.providers.openai_realtime import create_openai_realtime

    return create_openai_realtime(env)


def _gemini(env: Mapping[str, str]) -> llm.RealtimeModel:
    from coachw.providers.gemini import create_gemini_realtime

    return create_gemini_realtime(env)


def _xai(env: Mapping[str, str]) -> llm.RealtimeModel:
    from coachw.providers.xai_realtime import create_xai_realtime

    return create_xai_realtime(env)


PROVIDERS: dict[str, Callable[[Mapping[str, str]], llm.RealtimeModel]] = {
    "qwen": _qwen,
    "openai": _openai,
    "gemini": _gemini,
    "xai": _xai,
}


def default_provider(env: Mapping[str, str] = os.environ) -> str:
    return env.get("COACHW_PROVIDER", "").strip() or DEFAULT_PROVIDER


def allowed_providers(env: Mapping[str, str] = os.environ) -> tuple[str, ...]:
    """Providers this server exposes (`COACHW_PROVIDERS`, comma-separated; default all)."""
    raw = env.get("COACHW_PROVIDERS")
    if raw is None:
        return tuple(spec.id for spec in PROVIDER_SPECS)
    seen: list[str] = []
    for item in raw.split(","):
        name = item.strip()
        if name in PROVIDER_BY_ID and name not in seen:
            seen.append(name)
    return tuple(seen)


def is_provider_configured(name: str, env: Mapping[str, str] = os.environ) -> bool:
    spec = PROVIDER_BY_ID.get(name)
    if spec is None:
        return False
    return any(env.get(k, "").strip() for k in spec.env_keys)


def provider_catalog(env: Mapping[str, str] = os.environ) -> tuple[ProviderStatus, ...]:
    """All providers allowed on this server with live key-configuration status (never values)."""
    result: list[ProviderStatus] = []
    for name in allowed_providers(env):
        spec = PROVIDER_BY_ID[name]
        configured = is_provider_configured(name, env)
        result.append(
            ProviderStatus(
                id=spec.id,
                title=spec.title,
                detail=spec.detail,
                kind=spec.kind,
                configured=configured,
                missing_env="" if configured else spec.env_keys[0],
            )
        )
    return tuple(result)


def get_realtime_model(name: str, env: Mapping[str, str] = os.environ) -> llm.RealtimeModel:
    try:
        factory = PROVIDERS[name]
    except KeyError:
        raise ValueError(
            f"unknown realtime provider {name!r}; available: {sorted(PROVIDERS)}"
        ) from None
    return factory(env)


def create_agent_session(name: str, env: Mapping[str, str] = os.environ) -> AgentSession:
    """Create a LiveKit `AgentSession` for any supported voice provider (realtime or pipeline)."""
    if name == "openrouter":
        from coachw.providers.openrouter import create_openrouter_session

        return create_openrouter_session(env)
    if name in PROVIDERS:
        from livekit.agents import AgentSession

        return AgentSession(llm=get_realtime_model(name, env))
    raise ValueError(f"unknown voice provider {name!r}; available: {sorted(PROVIDER_BY_ID)}")
