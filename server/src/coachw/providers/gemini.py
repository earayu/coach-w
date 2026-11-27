"""Google Gemini Live API via `livekit-plugins-google`."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from google.genai import types as genai_types
from livekit.agents import llm
from livekit.plugins import google

DEFAULT_MODEL = "gemini-2.5-flash-native-audio-preview-12-2025"
DEFAULT_VOICE = "Puck"


@dataclass(frozen=True, slots=True)
class GeminiSettings:
    api_key: str
    model: str
    voice: str
    language: str | None

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> GeminiSettings:
        api_key = (env.get("GOOGLE_API_KEY") or env.get("GEMINI_API_KEY") or "").strip()
        if not api_key:
            raise ValueError("GOOGLE_API_KEY (or GEMINI_API_KEY) is required")
        return cls(
            api_key=api_key,
            model=env.get("GEMINI_REALTIME_MODEL", "").strip() or DEFAULT_MODEL,
            voice=env.get("GEMINI_VOICE", "").strip() or DEFAULT_VOICE,
            language=env.get("GEMINI_LANGUAGE", "").strip() or None,
        )


def create_gemini_realtime(env: Mapping[str, str]) -> llm.RealtimeModel:
    s = GeminiSettings.from_env(env)
    kwargs: dict = {
        "model": s.model,
        "voice": s.voice,
        "api_key": s.api_key,
        # Enable both transcriptions so user_input_transcribed, Transcript, VoiceStart and
        # FeedbackCatcher work identically to Qwen.
        "input_audio_transcription": genai_types.AudioTranscriptionConfig(),
        "output_audio_transcription": genai_types.AudioTranscriptionConfig(),
    }
    if s.language:
        kwargs["language"] = s.language
    return google.realtime.RealtimeModel(**kwargs)
