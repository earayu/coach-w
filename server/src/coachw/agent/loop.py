"""The once-a-second coach loop: asks the brain what to say and makes it happen (spec 4.2).

Timing is decided by `CoachBrain`; this loop only turns a delivery into speech
(`generate_reply(user_input=...)`), an interruption for emergencies, and a `coach.cue` for the
watch, and keeps the model's status summary fresh.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import time
from collections.abc import Awaitable, Callable
from typing import Protocol

from coachw.coach.brain import CoachBrain, Delivery
from coachw.protocol import CoachCue

logger = logging.getLogger("coachw.agent")

TICK_S = 1.0
SUMMARY_EVERY_S = 45.0
# Fragments of one sentence each start a turn; one refresh per couple of seconds is enough.
SPEAKING_REFRESH_S = 2.0

BUSY_AGENT_STATES = ("speaking", "thinking")


class Session(Protocol):
    @property
    def user_state(self) -> str: ...

    @property
    def agent_state(self) -> str: ...

    def generate_reply(self, *, user_input: str) -> object: ...

    def interrupt(self) -> object: ...


class Agent(Protocol):
    async def apply_profile(self) -> None: ...

    async def inject_status(self, text: str) -> None: ...


class Writer(Protocol):
    async def instructions_for(self, delivery: Delivery) -> str: ...


class CoachLoop:
    def __init__(
        self,
        brain: CoachBrain,
        agent: Agent,
        session: Session,
        publish_cue: Callable[[CoachCue], Awaitable[None]],
        clock: Callable[[], float] = time.monotonic,
        writer: Writer | None = None,
    ) -> None:
        self.writer = writer
        self.brain = brain
        self.agent = agent
        self.session = session
        self.publish_cue = publish_cue
        self.clock = clock
        self._profile_version = 0
        self._summary_at = clock()

    async def run(self) -> None:
        while True:
            try:
                await self.step()
            except Exception as e:
                # never let one bad tick end coaching; never log metric values
                logger.exception("coach loop step failed: %s", type(e).__name__)
            await asyncio.sleep(TICK_S)

    async def step(self) -> None:
        if self.brain.profile_version != self._profile_version:
            self._profile_version = self.brain.profile_version
            await self.agent.apply_profile()

        user_speaking = self.session.user_state == "speaking"
        agent_busy = self.session.agent_state in BUSY_AGENT_STATES
        delivery = self.brain.tick(user_speaking=user_speaking, agent_speaking=agent_busy)
        if delivery:
            await self.deliver(delivery)
            return

        if (
            not user_speaking
            and not agent_busy
            and self.clock() - self._summary_at >= SUMMARY_EVERY_S
        ):
            await self.refresh_status()

    async def athlete_started_speaking(self) -> None:
        """Put the watch's readings of this moment in front of the model before the athlete's
        turn ends: Qwen answers on its own at the end of the turn, often without calling
        get_metrics, and then had only old numbers or none (COCH-18)."""
        if self.clock() - self._summary_at < SPEAKING_REFRESH_S:
            return
        try:
            await self.refresh_status()
        except Exception as e:
            logger.warning("status refresh failed: %s", type(e).__name__)

    async def refresh_status(self) -> None:
        self._summary_at = self.clock()
        if text := self.brain.status_summary():
            await self.agent.inject_status(text)

    async def deliver(self, delivery: Delivery) -> None:
        cue = delivery.cue
        if delivery.interrupt:
            # the speech playing may refuse interruption; the emergency then waits behind it
            with contextlib.suppress(RuntimeError):
                self.session.interrupt()
        # A stronger text model may write the line first (spec 4.2.1); it falls back by itself.
        text = (
            await self.writer.instructions_for(delivery) if self.writer else delivery.instructions
        )
        # As a user-role text turn, not `instructions=`: Qwen ignores mid-conversation system
        # items and answers the last user turn instead (measured, spec 14.1).
        self.session.generate_reply(user_input=text)
        logger.info(
            "cue released id=%s kind=%s priority=%s interrupt=%s watch=%s written=%s",
            cue.id,
            cue.event.kind,
            cue.priority,
            delivery.interrupt,
            delivery.watch is not None,
            text != delivery.instructions,
        )
        if delivery.watch:
            try:
                await self.publish_cue(delivery.watch)
            except Exception as e:
                logger.warning("publish coach.cue failed: %s", type(e).__name__)
