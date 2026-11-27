import asyncio
from unittest.mock import AsyncMock

import pytest
from livekit.agents import AgentSession, llm
from livekit.plugins import aliyun, google, openai, silero, xai

from coachw.providers import (
    create_agent_session,
    get_realtime_model,
    is_provider_configured,
    provider_catalog,
)
from coachw.providers.gemini import GeminiSettings
from coachw.providers.openai_realtime import OpenAIRealtimeSettings
from coachw.providers.openrouter import OpenRouterSettings
from coachw.providers.qwen import QwenSettings, _RealtimeSession, pending_user_audio
from coachw.providers.writer import TextWriter
from coachw.providers.xai_realtime import XAISettings


def msg(id: str, role: str, *text: str) -> llm.ChatMessage:
    return llm.ChatMessage(id=id, role=role, content=list(text))


def test_pending_audio_turn_survives_tool_reply_sync():
    # Qwen created the user's audio turn; its transcript has not arrived yet
    remote = llm.ChatContext([msg("a1", "assistant", "hi"), msg("u1", "user")])
    framework_without_it = llm.ChatContext([msg("a1", "assistant", "hi")])
    framework_mirrored_empty = llm.ChatContext([msg("a1", "assistant", "hi"), msg("u1", "user")])
    assert [i.id for i in pending_user_audio(remote, framework_without_it)] == ["u1"]
    assert [i.id for i in pending_user_audio(remote, framework_mirrored_empty)] == ["u1"]


def test_transcribed_turns_sync_normally():
    remote = llm.ChatContext([msg("u1", "user")])
    transcribed = llm.ChatContext([msg("u1", "user", "我现在心率多少")])
    assert pending_user_audio(remote, transcribed) == []
    assert pending_user_audio(llm.ChatContext([msg("x", "assistant")]), llm.ChatContext()) == []


def test_unknown_provider():
    with pytest.raises(ValueError, match="unknown realtime provider"):
        get_realtime_model("nonexistent", {})
    with pytest.raises(ValueError, match="unknown voice provider"):
        create_agent_session("nonexistent", {})


def test_qwen_defaults():
    s = QwenSettings.from_env({"DASHSCOPE_API_KEY": "k"})
    assert s.model == "qwen-audio-3.1-realtime-flash"
    assert s.turn_detection == "server_vad"


def test_qwen_accepts_voicelab_key_name():
    assert QwenSettings.from_env({"QWEN_API_KEY": "k"}).api_key == "k"


def test_qwen_requires_key():
    with pytest.raises(ValueError, match="API_KEY"):
        get_realtime_model("qwen", {})


def test_qwen_rejects_unknown_turn_detection():
    with pytest.raises(ValueError, match="QWEN_TURN_DETECTION"):
        QwenSettings.from_env({"DASHSCOPE_API_KEY": "k", "QWEN_TURN_DETECTION": "smart_turn_v2"})


def test_qwen_builds_model():
    from livekit.plugins import aliyun

    model = get_realtime_model("qwen", {"DASHSCOPE_API_KEY": "k"})
    assert isinstance(model, aliyun.realtime.RealtimeModel)
    assert model._opts.turn_detection == {"type": "server_vad", "silence_duration_ms": 1200}


def test_qwen_turn_silence_is_configurable_within_qwens_range():
    s = QwenSettings.from_env({"DASHSCOPE_API_KEY": "k", "QWEN_VAD_SILENCE_MS": "900"})
    assert s.silence_ms == 900
    with pytest.raises(ValueError, match="QWEN_VAD_SILENCE_MS"):
        QwenSettings.from_env({"DASHSCOPE_API_KEY": "k", "QWEN_VAD_SILENCE_MS": "100"})


def test_pending_audio_is_restored_when_update_chat_ctx_fails(monkeypatch):
    session = object.__new__(_RealtimeSession)
    pending = msg("u1", "user")
    session._chat_ctx = llm.ChatContext([msg("a1", "assistant", "hi"), pending])

    async def boom(self, chat_ctx):
        raise RuntimeError("ws closed")

    monkeypatch.setattr(aliyun.realtime.RealtimeSession, "update_chat_ctx", boom)
    with pytest.raises(RuntimeError, match="ws closed"):
        asyncio.run(session.update_chat_ctx(llm.ChatContext([msg("a1", "assistant", "hi")])))
    assert session._chat_ctx.get_by_id("u1") is not None


def test_text_writer_aclose_closes_underlying_http_client():
    writer = TextWriter("qwen3.8-flash", {"DASHSCOPE_API_KEY": "k"})
    close = AsyncMock()
    writer._llm._client.close = close
    asyncio.run(writer.aclose())
    close.assert_awaited_once()


def test_text_writer_supports_openrouter_models():
    writer = TextWriter("google/gemini-2.5-flash", {"OPENROUTER_API_KEY": "or-k"})
    assert isinstance(writer._llm, openai.LLM)
    with pytest.raises(ValueError, match="OPENROUTER_API_KEY"):
        TextWriter("google/gemini-2.5-flash", {})


def test_openai_realtime_builds_model_and_custom_base_url():
    s = OpenAIRealtimeSettings.from_env(
        {
            "OPENAI_API_KEY": "sk-test",
            "OPENAI_REALTIME_BASE_URL": "https://relay.example.com/v1",
            "OPENAI_VAD_SILENCE_MS": "900",
        }
    )
    assert s.model == "gpt-realtime"
    assert s.base_url == "https://relay.example.com/v1"
    assert s.silence_ms == 900
    model = get_realtime_model(
        "openai",
        {"OPENAI_API_KEY": "sk-test", "OPENAI_REALTIME_BASE_URL": "https://relay.example.com/v1"},
    )
    assert isinstance(model, openai.realtime.RealtimeModel)
    assert model._opts.base_url == "https://relay.example.com/v1"
    with pytest.raises(ValueError, match="OPENAI_API_KEY"):
        get_realtime_model("openai", {})
    with pytest.raises(ValueError, match="OPENAI_VAD_SILENCE_MS"):
        OpenAIRealtimeSettings.from_env({"OPENAI_API_KEY": "k", "OPENAI_VAD_SILENCE_MS": "50"})


def test_gemini_realtime_builds_model_with_transcriptions():
    assert GeminiSettings.from_env({"GEMINI_API_KEY": "gk"}).api_key == "gk"
    model = get_realtime_model("gemini", {"GOOGLE_API_KEY": "gk"})
    assert isinstance(model, google.realtime.RealtimeModel)
    assert model.capabilities.user_transcription is True
    with pytest.raises(ValueError, match="GOOGLE_API_KEY"):
        get_realtime_model("gemini", {})


def test_xai_realtime_builds_model():
    s = XAISettings.from_env({"XAI_API_KEY": "xk", "XAI_VAD_SILENCE_MS": "800"})
    assert s.model == "grok-voice-latest"
    assert s.silence_ms == 800
    model = get_realtime_model("xai", {"XAI_API_KEY": "xk"})
    assert isinstance(model, xai.realtime.RealtimeModel)
    with pytest.raises(ValueError, match="XAI_API_KEY"):
        get_realtime_model("xai", {})


def test_openrouter_creates_stt_llm_tts_session():
    s = OpenRouterSettings.from_env({"OPENROUTER_API_KEY": "or-k"})
    assert s.base_url == "https://openrouter.ai/api/v1"
    assert s.llm_model == "google/gemini-2.5-flash"

    async def build() -> AgentSession:
        return create_agent_session("openrouter", {"OPENROUTER_API_KEY": "or-k"})

    session = asyncio.run(build())
    assert isinstance(session, AgentSession)
    assert isinstance(session.vad, silero.VAD)
    assert isinstance(session.stt, openai.STT)
    assert isinstance(session.llm, openai.LLM)
    assert isinstance(session.tts, openai.TTS)
    assert not session.stt.capabilities.streaming
    with pytest.raises(ValueError, match="OPENROUTER_API_KEY"):
        create_agent_session("openrouter", {})


def test_provider_catalog_reflects_configured_keys_and_allowlist():
    env = {"DASHSCOPE_API_KEY": "d", "OPENROUTER_API_KEY": "o"}
    assert is_provider_configured("qwen", env)
    assert is_provider_configured("openrouter", env)
    assert not is_provider_configured("openai", env)

    catalog = {p.id: p for p in provider_catalog(env)}
    assert catalog["qwen"].configured is True
    assert catalog["qwen"].missing_env == ""
    assert catalog["openrouter"].configured is True
    assert catalog["openrouter"].kind == "pipeline"
    assert catalog["openai"].configured is False
    assert catalog["openai"].missing_env == "OPENAI_API_KEY"

    filtered = provider_catalog(env | {"COACHW_PROVIDERS": "openrouter, qwen, bogus"})
    assert [p.id for p in filtered] == ["openrouter", "qwen"]
