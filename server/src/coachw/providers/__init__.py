"""Realtime model registry.

Vendor SDKs and plugins are imported only inside this package (AGENTS.md), so switching models
never touches coach code. Each provider reads its own settings from the environment.
"""

from __future__ import annotations

import os
from collections.abc import Callable, Mapping
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from livekit.agents import llm


def _qwen(env: Mapping[str, str]) -> llm.RealtimeModel:
    from coachw.providers.qwen import create_qwen_realtime

    return create_qwen_realtime(env)


PROVIDERS: dict[str, Callable[[Mapping[str, str]], llm.RealtimeModel]] = {"qwen": _qwen}


def get_realtime_model(name: str, env: Mapping[str, str] = os.environ) -> llm.RealtimeModel:
    try:
        factory = PROVIDERS[name]
    except KeyError:
        raise ValueError(
            f"unknown realtime provider {name!r}; available: {sorted(PROVIDERS)}"
        ) from None
    return factory(env)
