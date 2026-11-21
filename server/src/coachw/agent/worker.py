"""LiveKit agent worker: one coach session per room (spec 7.2, 4).

Run: `python -m coachw.agent dev` (local) or `python -m coachw.agent start` (production).
LiveKit Agents reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from the environment.
"""

from __future__ import annotations

import asyncio
import contextlib
import logging
import os

from livekit import rtc
from livekit.agents import AgentServer, AgentSession, JobContext, cli

from coachw.agent.coach import GREETING, SESSION_CAP_FAREWELL, CoachAgent
from coachw.agent.loop import CoachLoop
from coachw.coach.brain import CoachBrain
from coachw.profiles.base import Athlete
from coachw.protocol import CUE_TOPIC, METRICS_TOPIC, CoachCue, MetricsFrame, ProtocolError
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


def make_metrics_listener(brain: CoachBrain, athlete_identity: str):
    def on_data(packet: rtc.DataPacket) -> None:
        if packet.topic != METRICS_TOPIC:
            return
        if packet.participant is None or packet.participant.identity != athlete_identity:
            return
        try:
            brain.on_frame(MetricsFrame.from_json(packet.data))
        except (ProtocolError, ValueError, TypeError) as e:
            # never log the payload: it is health data
            logger.warning("dropped bad metrics frame: %s", type(e).__name__)

    return on_data


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
    participant = await ctx.wait_for_participant()
    meta = read_session_meta(participant)
    ctx.log_context_fields = {"athlete_id": meta.athlete_id, "room": ctx.room.name}

    # all coaching state is per session and per athlete (spec 3.1)
    brain = CoachBrain(Athlete(athlete_id=meta.athlete_id))
    ctx.room.on("data_received", make_metrics_listener(brain, participant.identity))

    session = AgentSession(llm=get_realtime_model(os.environ.get("COACHW_PROVIDER", "qwen")))
    agent = CoachAgent(brain)

    async def publish_cue(cue: CoachCue) -> None:
        await ctx.room.local_participant.publish_data(
            cue.to_json(),
            reliable=True,
            destination_identities=[participant.identity],
            topic=CUE_TOPIC,
        )

    await session.start(room=ctx.room, agent=agent)
    cap = asyncio.create_task(end_when_cap_reached(ctx, session, meta.max_session_s))
    coach = asyncio.create_task(CoachLoop(brain, agent, session, publish_cue).run())
    ctx.add_shutdown_callback(lambda: _cancel(cap, coach))
    logger.info("coach session started, cap %ds", meta.max_session_s)

    session.generate_reply(instructions=GREETING)


async def _cancel(*tasks: asyncio.Task) -> None:
    for task in tasks:
        task.cancel()


def main() -> None:
    cli.run_app(server)
