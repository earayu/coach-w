"""OpenRouter voice pipeline (STT + LLM + TTS + local Silero VAD) using a single OPENROUTER_API_KEY.

OpenRouter officially does not expose `/v1/realtime` WebSockets
(https://openrouter.ai/docs/guides/features/compatibility), so an OpenRouter key drives a
LiveKit `AgentSession` via OpenRouter's OpenAI-compatible `/api/v1/audio/transcriptions`,
`/api/v1/chat/completions`, and `/api/v1/audio/speech` endpoints paired with local Silero VAD.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from livekit.agents import AgentSession
from livekit.plugins import openai, silero

DEFAULT_BASE_URL = "https://openrouter.ai/api/v1"
DEFAULT_LLM_MODEL = "google/gemini-2.5-flash"
DEFAULT_STT_MODEL = "openai/gpt-4o-mini-transcribe"
DEFAULT_STT_LANGUAGE = "zh"
DEFAULT_TTS_MODEL = "google/gemini-2.5-flash-tts"
DEFAULT_TTS_VOICE = "Kore"
VAD_SILENCE_MS = 1200


def _silence_ms(raw: str) -> int:
    value = int(raw)
    if not 200 <= value <= 6000:
        raise ValueError(f"OPENROUTER_VAD_SILENCE_MS must be 200-6000, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class OpenRouterSettings:
    api_key: str
    base_url: str
    llm_model: str
    stt_model: str
    stt_language: str
    tts_model: str
    tts_voice: str
    silence_ms: int

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> OpenRouterSettings:
        api_key = env.get("OPENROUTER_API_KEY", "").strip()
        if not api_key:
            raise ValueError("OPENROUTER_API_KEY is required")
        return cls(
            api_key=api_key,
            base_url=env.get("OPENROUTER_BASE_URL", "").strip() or DEFAULT_BASE_URL,
            llm_model=env.get("OPENROUTER_LLM_MODEL", "").strip() or DEFAULT_LLM_MODEL,
            stt_model=env.get("OPENROUTER_STT_MODEL", "").strip() or DEFAULT_STT_MODEL,
            stt_language=env.get("OPENROUTER_STT_LANGUAGE", "").strip() or DEFAULT_STT_LANGUAGE,
            tts_model=env.get("OPENROUTER_TTS_MODEL", "").strip() or DEFAULT_TTS_MODEL,
            tts_voice=env.get("OPENROUTER_TTS_VOICE", "").strip() or DEFAULT_TTS_VOICE,
            silence_ms=_silence_ms(env.get("OPENROUTER_VAD_SILENCE_MS", str(VAD_SILENCE_MS))),
        )


def create_openrouter_session(env: Mapping[str, str]) -> AgentSession:
    s = OpenRouterSettings.from_env(env)
    vad = silero.VAD.load(min_silence_duration=s.silence_ms / 1000.0)
    stt = openai.STT(
        model=s.stt_model,
        language=s.stt_language,
        base_url=s.base_url,
        api_key=s.api_key,
        use_realtime=False,
    )
    chat_llm = openai.LLM.with_openrouter(
        model=s.llm_model,
        api_key=s.api_key,
        base_url=s.base_url,
    )
    tts = openai.TTS(
        model=s.tts_model,
        voice=s.tts_voice,
        base_url=s.base_url,
        api_key=s.api_key,
        # MP3 carries its own sample rate header so LiveKit decodes and resamples any upstream
        # provider cleanly without PCM sample-rate mismatches.
        response_format="mp3",
    )
    return AgentSession(vad=vad, stt=stt, llm=chat_llm, tts=tts)
