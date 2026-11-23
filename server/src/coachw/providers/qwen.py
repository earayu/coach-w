"""Qwen realtime via the community `livekit-plugins-aliyun` plugin (migrated from voicelab)."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass

from livekit.agents import llm
from livekit.plugins import aliyun

TURN_DETECTION = ("server_vad", "smart_turn")
# Silence that ends the athlete's turn. A runner pauses to breathe mid-sentence: with Qwen's
# default one sentence arrived as two or three fragments and the coach cut in after the first
# (COCH-15). Qwen accepts 200-6000 ms.
VAD_SILENCE_MS = 1200


def _silence_ms(raw: str) -> int:
    value = int(raw)
    if not 200 <= value <= 6000:
        raise ValueError(f"QWEN_VAD_SILENCE_MS must be 200-6000, got {value}")
    return value


@dataclass(frozen=True, slots=True)
class QwenSettings:
    api_key: str
    model: str
    voice: str
    turn_detection: str
    base_url: str | None
    silence_ms: int

    @classmethod
    def from_env(cls, env: Mapping[str, str]) -> QwenSettings:
        api_key = env.get("DASHSCOPE_API_KEY") or env.get("QWEN_API_KEY", "")
        if not api_key:
            raise ValueError("DASHSCOPE_API_KEY (or QWEN_API_KEY) is required")
        # server_vad: interruptions take ~0.5 s; smart_turn ~5 s (voicelab, spec 7.1)
        turn = env.get("QWEN_TURN_DETECTION", "server_vad").strip()
        if turn not in TURN_DETECTION:
            raise ValueError(f"QWEN_TURN_DETECTION must be one of {TURN_DETECTION}, got {turn!r}")
        return cls(
            api_key=api_key,
            model=env.get("QWEN_REALTIME_MODEL", "qwen-audio-3.1-realtime-flash"),
            voice=env.get("QWEN_VOICE", "longanqian_v3.1"),
            turn_detection=turn,
            base_url=env.get("QWEN_REALTIME_BASE_URL") or None,
            silence_ms=_silence_ms(env.get("QWEN_VAD_SILENCE_MS", str(VAD_SILENCE_MS))),
        )


def _is_pending_user_audio(item: llm.ChatItem) -> bool:
    return item.type == "message" and item.role == "user" and not item.content


def pending_user_audio(remote: llm.ChatContext, target: llm.ChatContext) -> list[llm.ChatItem]:
    """User turns Qwen created from audio whose transcript has not arrived in either context."""
    return [
        item
        for item in remote.items
        if _is_pending_user_audio(item)
        and ((t := target.get_by_id(item.id)) is None or _is_pending_user_audio(t))
    ]


class _RealtimeSession(aliyun.realtime.RealtimeSession):
    async def update_chat_ctx(self, chat_ctx: llm.ChatContext) -> None:
        # Qwen can call a tool before the user's audio turn is transcribed. That turn is still
        # empty here, so the plugin (1.8.10) drops it from the target context and *deletes* it on
        # the server: the follow-up answer then replies to an older text message instead of the
        # question (measured 2026-11-21, spec 14.1). Hide pending turns from the diff and keep them.
        pending = pending_user_audio(self._chat_ctx, chat_ctx)
        for item in pending:
            self._chat_ctx.items.remove(item)
        try:
            await super().update_chat_ctx(chat_ctx)
        finally:
            for item in pending:
                if self._chat_ctx.get_by_id(item.id) is None:
                    self._chat_ctx.insert(item)


class _RealtimeModel(aliyun.realtime.RealtimeModel):
    def session(self, *, turn_detection_disabled: bool = False) -> _RealtimeSession:
        session = _RealtimeSession(self, turn_detection_disabled=turn_detection_disabled)
        self._sessions.add(session)
        return session


def create_qwen_realtime(env: Mapping[str, str]) -> llm.RealtimeModel:
    s = QwenSettings.from_env(env)
    kwargs: dict = {
        "model": s.model,
        "voice": s.voice,
        "turn_detection": (
            {"type": "server_vad", "silence_duration_ms": s.silence_ms}
            if s.turn_detection == "server_vad"
            else {"type": s.turn_detection}
        ),
        "api_key": s.api_key,
    }
    if s.base_url:
        kwargs["base_url"] = s.base_url
    return _RealtimeModel(**kwargs)
