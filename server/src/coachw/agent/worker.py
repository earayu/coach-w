"""LiveKit agent worker: one coach session per room (spec 7.2, 4).

Run: `python -m coachw.agent dev` (local) or `python -m coachw.agent start` (production).
LiveKit Agents reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from the environment.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os
from typing import Any

from livekit import rtc
from livekit.agents import AgentServer, AgentSession, JobContext, cli

from coachw.agent.coach import GREETING, SESSION_CAP_FAREWELL, CoachAgent
from coachw.agent.loop import CoachLoop
from coachw.agent.transcript import Transcript, transcript_dir
from coachw.coach.brain import CoachBrain
from coachw.profiles.base import Athlete
from coachw.protocol import (
    CUE_TOPIC,
    METRICS_TOPIC,
    RESUME_TOPIC,
    CoachCue,
    CoachResume,
    MetricsFrame,
    ProtocolError,
)
from coachw.providers import get_realtime_model
from coachw.session import AGENT_NAME, SessionMeta

logger = logging.getLogger("coachw.agent")

server = AgentServer(
    # LiveKit's production default prewarms 8 job processes; too many for a 2-core / 4 GB host
    num_idle_processes=int(os.environ.get("COACHW_AGENT_IDLE_PROCESSES", "2")),
    # the default 10 s is not always enough to import the plugin stack on a busy host
    initialize_process_timeout=30.0,
    # health endpoint (8081 in production) is for the host only; the default binds every interface
    host="127.0.0.1",
)


def read_session_meta(participant: rtc.RemoteParticipant) -> SessionMeta:
    """Session limits signed by the token API. Fall back to the local default when absent."""
    try:
        return SessionMeta.from_json(participant.metadata)
    except (ValueError, KeyError, TypeError):
        fallback = int(os.environ.get("COACHW_SESSION_MAX_MINUTES", "60")) * 60
        logger.warning("participant has no valid session metadata; using %ds cap", fallback)
        return SessionMeta(athlete_id="unknown", max_session_s=fallback)


# How long a new session waits for `coach.resume` before greeting as if the workout is new.
RESUME_WAIT_S = 2.0
# Packets kept while the athlete is not known yet (the agent joins after the phone).
INBOX_LIMIT = 64


class AthleteInbox:
    """Routes the athlete's data packets to the session's brain.

    Registered as soon as the agent is in the room, so a `coach.resume` the phone sends the moment
    the agent joins is not lost while the agent still waits for the participant; packets are held
    until `attach` names the athlete. Only that participant is listened to.
    """

    def __init__(self) -> None:
        self.brain: CoachBrain | None = None
        self.identity: str | None = None
        self.resumed = asyncio.Event()
        self.frames = 0
        self._held: list[rtc.DataPacket] = []

    def attach(self, brain: CoachBrain, athlete_identity: str) -> None:
        self.brain, self.identity = brain, athlete_identity
        held, self._held = self._held, []
        for packet in held:
            self.on_data(packet)

    def on_data(self, packet: rtc.DataPacket) -> None:
        if packet.topic not in (METRICS_TOPIC, RESUME_TOPIC):
            return
        if self.brain is None:
            if len(self._held) < INBOX_LIMIT:
                self._held.append(packet)
            return
        if packet.participant is None or packet.participant.identity != self.identity:
            return
        try:
            if packet.topic == METRICS_TOPIC:
                self.brain.on_frame(MetricsFrame.from_json(packet.data))
                self.frames += 1
                if self.frames == 1:
                    logger.info("first metrics frame received")
            elif self.brain.resume(CoachResume.from_json(packet.data)):
                # counts only, never the values: they are health data
                logger.info("workout resumed with %d splits", len(self.brain.state.splits))
                self.resumed.set()
        except (ProtocolError, ValueError, TypeError) as e:
            # never log the payload: it is health data
            logger.warning("dropped bad %s packet: %s", packet.topic, type(e).__name__)


class TurnLog:
    """Counts what happened in a session so a silent coach can be told apart from a deaf one.

    Logs only counts and lengths, never the words: they are the athlete's conversation (spec 11).
    """

    def __init__(self) -> None:
        self.user_turns = 0
        self.coach_replies = 0
        self.errors = 0

    def on_user_input(self, ev: Any) -> None:
        if not ev.is_final:
            return
        self.user_turns += 1
        logger.info("user turn transcribed chars=%d", len(ev.transcript))

    def on_item_added(self, ev: Any) -> None:
        if getattr(ev.item, "role", None) == "assistant":
            self.coach_replies += 1

    def on_error(self, ev: Any) -> None:
        self.errors += 1
        source, error = type(ev.source).__name__, type(ev.error).__name__
        logger.warning("session error from %s: %s", source, error)

    def attach(self, session: AgentSession) -> None:
        session.on("user_input_transcribed", self.on_user_input)
        session.on("conversation_item_added", self.on_item_added)
        session.on("error", self.on_error)

    def summary(self, frames: int) -> str:
        return (
            f"session summary: frames={frames} user_turns={self.user_turns} "
            f"coach_replies={self.coach_replies} errors={self.errors}"
        )


async def greeting_for(brain: CoachBrain, inbox: AthleteInbox) -> str:
    """The first-time greeting, or a short "I'm back" when the phone resumes a workout."""
    with contextlib.suppress(TimeoutError):
        await asyncio.wait_for(inbox.resumed.wait(), RESUME_WAIT_S)
    return brain.resume_greeting() or GREETING


async def end_when_cap_reached(ctx: JobContext, session: AgentSession, seconds: int) -> None:
    await asyncio.sleep(seconds)
    logger.info("session cap reached after %ds", seconds)
    with contextlib.suppress(Exception):
        handle = session.generate_reply(
            instructions=SESSION_CAP_FAREWELL, allow_interruptions=False
        )
        await asyncio.wait_for(handle.wait_for_playout(), timeout=20)
    await ctx.delete_room()
    ctx.shutdown("session cap reached")


@server.rtc_session(agent_name=AGENT_NAME)
async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    inbox = AthleteInbox()
    ctx.room.on("data_received", inbox.on_data)
    participant = await ctx.wait_for_participant()
    meta = read_session_meta(participant)
    ctx.log_context_fields = {"athlete_id": meta.athlete_id, "room": ctx.room.name}

    # all coaching state is per session and per athlete (spec 3.1)
    brain = CoachBrain(Athlete(athlete_id=meta.athlete_id))
    inbox.attach(brain, participant.identity)

    session = AgentSession(llm=get_realtime_model(os.environ.get("COACHW_PROVIDER", "qwen")))
    agent = CoachAgent(brain)
    turns = TurnLog()
    turns.attach(session)
    if (directory := transcript_dir()) is not None:
        transcript = Transcript(directory, room=ctx.room.name, athlete_id=meta.athlete_id)
        transcript.attach(session)
        logger.info("keeping the transcript in %s", transcript.path.name)

    async def log_summary() -> None:
        logger.info(turns.summary(inbox.frames))

    ctx.add_shutdown_callback(log_summary)

    async def publish_cue(cue: CoachCue) -> None:
        await ctx.room.local_participant.publish_data(
            cue.to_json(),
            reliable=True,
            destination_identities=[participant.identity],
            topic=CUE_TOPIC,
        )

    await session.start(room=ctx.room, agent=agent)
    cap = asyncio.create_task(end_when_cap_reached(ctx, session, meta.max_session_s))
    ctx.add_shutdown_callback(lambda: _cancel(cap))
    logger.info("coach session started, cap %ds", meta.max_session_s)

    # The greeting goes first: it is an `instructions=` reply, which Qwen only follows while the
    # conversation has no user turn yet, and cues are user turns (spec 4.2, 14.1).
    session.generate_reply(instructions=await greeting_for(brain, inbox))
    coach = asyncio.create_task(CoachLoop(brain, agent, session, publish_cue).run())
    ctx.add_shutdown_callback(lambda: _cancel(coach))


async def _cancel(*tasks: asyncio.Task) -> None:
    for task in tasks:
        task.cancel()


def main() -> None:
    cli.run_app(server)
