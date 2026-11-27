"""Text models that write what the coach says before the realtime model speaks it (spec 4.2.1).

Supports DashScope models via `livekit-plugins-aliyun` (e.g. `qwen3.8-flash`) and OpenRouter
models (containing `/`, e.g. `google/gemini-2.5-flash`) via `livekit-plugins-openai`. Thinking is
disabled on DashScope models: a cue must be said within a second or two.
"""

from __future__ import annotations

import asyncio
import logging
from collections.abc import Mapping

from livekit.agents import APIConnectOptions, llm
from livekit.plugins import aliyun, openai

logger = logging.getLogger("coachw.agent")

WRITE_TIMEOUT_S = 4.0
DEFAULT_OPENROUTER_BASE_URL = "https://openrouter.ai/api/v1"


class TextWriter:
    def __init__(self, model: str, env: Mapping[str, str]) -> None:
        self.model = model
        self._extra_kwargs: dict | None = None
        if "/" in model:
            api_key = env.get("OPENROUTER_API_KEY", "").strip()
            if not api_key:
                raise ValueError("OPENROUTER_API_KEY is required")
            base_url = env.get("OPENROUTER_BASE_URL", "").strip() or DEFAULT_OPENROUTER_BASE_URL
            self._llm: llm.LLM = openai.LLM.with_openrouter(
                model=model, api_key=api_key, base_url=base_url
            )
        else:
            api_key = env.get("DASHSCOPE_API_KEY") or env.get("QWEN_API_KEY", "")
            if not api_key:
                raise ValueError("DASHSCOPE_API_KEY (or QWEN_API_KEY) is required")
            self._llm = aliyun.LLM(model=model, api_key=api_key)
            self._extra_kwargs = {"extra_body": {"enable_thinking": False}}

    async def write(self, system: str, prompt: str) -> str | None:
        """The text, or None when the model failed or took too long (the caller falls back)."""
        ctx = llm.ChatContext()
        ctx.add_message(role="system", content=system)
        ctx.add_message(role="user", content=prompt)
        try:
            return await asyncio.wait_for(self._collect(ctx), WRITE_TIMEOUT_S) or None
        except Exception as e:  # timeout, quota, network: never block a cue on it
            logger.warning("writer %s failed: %s", self.model, type(e).__name__)
            return None

    async def aclose(self) -> None:
        await self._llm._client.close()

    async def _collect(self, ctx: llm.ChatContext) -> str:
        parts: list[str] = []
        kwargs: dict = {
            "chat_ctx": ctx,
            "conn_options": APIConnectOptions(max_retry=0, timeout=WRITE_TIMEOUT_S),
        }
        if self._extra_kwargs is not None:
            kwargs["extra_kwargs"] = self._extra_kwargs
        async with self._llm.chat(**kwargs) as stream:
            async for chunk in stream:
                if chunk.delta and chunk.delta.content:
                    parts.append(chunk.delta.content)
        return "".join(parts).strip()
