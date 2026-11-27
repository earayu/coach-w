"""OpenAI Realtime API via `livekit-plugins-openai` (also supports custom compatible base URLs)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from livekit.agents import llm
from livekit.plugins import openai
from openai.types.realtime import AudioTranscription
from openai.types.realtime.realtime_audio_input_turn_detection import ServerVad

DEFAULT_MODEL = "gpt-realtime"
DEFAULT_VOICE = "marin"
DEFAULT_TRANSCRIBE_MODEL = "gpt-4o-mini-transcribe"
VAD_SILENCE_MS = 1200


def _silence_ms(raw: str) -> int:
    value = int(raw)
    if not 200 <= value <= 6000:
        raise ValueError(f"OPENAI_VAD_SILENCE_MS must be 200-6000, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class OpenAIRealtimeSettings:
    api_key: str
    model: str
    voice: str
    transcribe_model: str
    base_url: str | None
    silence_ms: int

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> OpenAIRealtimeSettings:
        api_key = env.get("OPENAI_API_KEY", "").strip()
        if not api_key:
            raise ValueError("OPENAI_API_KEY is required")
        return cls(
            api_key=api_key,
            model=env.get("OPENAI_REALTIME_MODEL", "").strip() or DEFAULT_MODEL,
            voice=env.get("OPENAI_REALTIME_VOICE", "").strip() or DEFAULT_VOICE,
            transcribe_model=env.get("OPENAI_TRANSCRIBE_MODEL", "").strip()
            or DEFAULT_TRANSCRIBE_MODEL,
            base_url=env.get("OPENAI_REALTIME_BASE_URL", "").strip() or None,
            silence_ms=_silence_ms(env.get("OPENAI_VAD_SILENCE_MS", str(VAD_SILENCE_MS))),
        )


def create_openai_realtime(env: Mapping[str, str]) -> llm.RealtimeModel:
    s = OpenAIRealtimeSettings.from_env(env)
    kwargs: dict = {
        "model": s.model,
        "voice": s.voice,
        "api_key": s.api_key,
        "input_audio_transcription": AudioTranscription(model=s.transcribe_model, language="zh"),
        "turn_detection": ServerVad(
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
    return openai.realtime.RealtimeModel(**kwargs)
