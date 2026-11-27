"""xAI Grok Voice Realtime API via `livekit-plugins-xai`."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from livekit.agents import llm
from livekit.plugins import xai

DEFAULT_MODEL = "grok-voice-latest"
DEFAULT_VOICE = "Ara"
VAD_SILENCE_MS = 1200


def _silence_ms(raw: str) -> int:
    value = int(raw)
    if not 200 <= value <= 6000:
        raise ValueError(f"XAI_VAD_SILENCE_MS must be 200-6000, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class XAISettings:
    api_key: str
    model: str
    voice: str
    base_url: str | None
    silence_ms: int

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> XAISettings:
        api_key = env.get("XAI_API_KEY", "").strip()
        if not api_key:
            raise ValueError("XAI_API_KEY is required")
        return cls(
            api_key=api_key,
            model=env.get("XAI_REALTIME_MODEL", "").strip() or DEFAULT_MODEL,
            voice=env.get("XAI_VOICE", "").strip() or DEFAULT_VOICE,
            base_url=env.get("XAI_REALTIME_BASE_URL", "").strip() or None,
            silence_ms=_silence_ms(env.get("XAI_VAD_SILENCE_MS", str(VAD_SILENCE_MS))),
        )


def create_xai_realtime(env: Mapping[str, str]) -> llm.RealtimeModel:
    s = XAISettings.from_env(env)
    kwargs: dict = {
        "model": s.model,
        "voice": s.voice,
        "api_key": s.api_key,
        "turn_detection": xai.realtime.TurnDetection(
            type="server_vad",
            threshold=0.5,
            prefix_padding_ms=300,
            silence_duration_ms=s.silence_ms,
            create_response=True,
            interrupt_response=True,
        ),
    }
    if s.base_url:
        kwargs["base_url"] = s.base_url
    return xai.realtime.RealtimeModel(**kwargs)
