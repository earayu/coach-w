import asyncio
from unittest.mock import AsyncMock

import pytest
from livekit.agents import llm
from livekit.plugins import aliyun

from coachw.providers import get_realtime_model
from coachw.providers.qwen import QwenSettings, _RealtimeSession, pending_user_audio
from coachw.providers.writer import TextWriter


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
        get_realtime_model("openai", {})


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
