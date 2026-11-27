"""LiveKit agent worker: one coach session per room (spec 7.2, 4).

Run: `python -m coachw.agent dev` (local) or `python -m coachw.agent start` (production).
LiveKit Agents reads LIVEKIT_URL / LIVEKIT_API_KEY / LIVEKIT_API_SECRET from the environment.
"""

from __future__ import annotations

import asyncio
import contextlib
import json
import logging
import os
import time
from datetime import UTC, datetime, tzinfo
from typing import Any
from zoneinfo import ZoneInfo

from livekit import rtc
from livekit.agents import AgentServer, AgentSession, JobContext, cli

from coachw.agent.coach import (
    GREETING,
    PRE_WORKOUT_GREETING,
    RECONNECT_GREETING,
    SESSION_CAP_FAREWELL,
    CoachAgent,
    cap_farewell,
)
from coachw.agent.cue_writer import CueWriter, conversation_of
from coachw.agent.feedback import FeedbackCatcher
from coachw.agent.loop import CoachLoop
from coachw.agent.memory import AthleteMemory
from coachw.agent.transcript import Transcript, recent_conversation, transcript_dir
from coachw.agent.turns import TurnGuard, is_empty_turn
from coachw.agent.voice_start import VoiceStart, control_heard
from coachw.coach.brain import DEFAULT_TZ, CoachBrain
from coachw.profiles.base import Athlete
from coachw.protocol import (
    CUE_TOPIC,
    METRICS_TOPIC,
    RESUME_TOPIC,
    CoachCue,
    CoachResume,
    MetricsFrame,
    ProtocolError,
    WorkoutState,
)
from coachw.providers import get_realtime_model
from coachw.providers.writer import TextWriter
from coachw.session import (
    AGENT_NAME,
    CONTROL_METHOD,
    HEARTBEAT_METHOD,
    HISTORY_METHOD,
    PLACES_METHOD,
    START_METHOD,
    SessionMeta,
    writer_models,
)

logger = logging.getLogger("coachw.agent")

server = AgentServer(
    # LiveKit's production default prewarms 8 job processes; too many for a 2-core / 4 GB host
    num_idle_processes=int(os.environ.get("COACHW_AGENT_IDLE_PROCESSES", "2")),
    # the default 10 s is not always enough to import the plugin stack on a busy host
    initialize_process_timeout=30.0,
    # health endpoint (8081 in production) is for the host only; the default binds every interface
    host="127.0.0.1",
)


# With a cue writer, the coach is woken this long after anyone last spoke and decides itself
# whether to say something (spec 4.2.2).
CHECK_IN_S = 75.0


def check_in_s() -> float | None:
    value = float(os.environ.get("COACHW_CHECK_IN_S", str(CHECK_IN_S)))
    return value if value > 0 else None


def athlete_tz() -> tzinfo:
    name = os.environ.get("COACHW_TZ", "").strip()
    return ZoneInfo(name) if name else DEFAULT_TZ


def session_max_s() -> int:
    """The per-session maximum the token API also uses (same environment)."""
    return int(os.environ.get("COACHW_SESSION_MAX_MINUTES", "60")) * 60


def read_session_meta(participant: rtc.RemoteParticipant) -> SessionMeta:
    """Session limits signed by the token API. Fall back to the local default when absent."""
    try:
        return SessionMeta.from_json(participant.metadata)
    except (ValueError, KeyError, TypeError):
        fallback = session_max_s()
        logger.warning("participant has no valid session metadata; using %ds cap", fallback)
        return SessionMeta(athlete_id="unknown", max_session_s=fallback)


# A new coach continues what was said this recently (COCH-15), up to this many lines.
HISTORY_MAX_AGE_S = 30 * 60
HISTORY_LINES = 30
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

    def __init__(self, clock: Any = time.monotonic) -> None:
        self.user_turns = 0
        self.coach_replies = 0
        self.errors = 0
        self._clock = clock
        self._turn_ended_at: float | None = None

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

    def on_user_state(self, ev: Any) -> None:
        if ev.old_state == "speaking" and ev.new_state != "speaking":
            self._turn_ended_at = self._clock()

    def on_agent_state(self, ev: Any) -> None:
        # how long the athlete waited for the coach after they stopped talking (COCH-22)
        if ev.new_state == "speaking" and self._turn_ended_at is not None:
            logger.info(
                "coach answered %.1fs after the athlete stopped",
                self._clock() - self._turn_ended_at,
            )
            self._turn_ended_at = None

    def attach(self, session: AgentSession) -> None:
        session.on("user_input_transcribed", self.on_user_input)
        session.on("conversation_item_added", self.on_item_added)
        session.on("error", self.on_error)
        session.on("user_state_changed", self.on_user_state)
        session.on("agent_state_changed", self.on_agent_state)

    def summary(self, frames: int) -> str:
        return (
            f"session summary: frames={frames} user_turns={self.user_turns} "
            f"coach_replies={self.coach_replies} errors={self.errors}"
        )


async def greeting_for(brain: CoachBrain, inbox: AthleteInbox) -> str:
    """The first-time greeting, or a short "I'm back" when the phone resumes a workout."""
    with contextlib.suppress(TimeoutError):
        await asyncio.wait_for(inbox.resumed.wait(), RESUME_WAIT_S)
    if resumed := brain.resume_greeting():
        return resumed
    # connected before the watch started (spec 7.6): talk about the plan, not live numbers
    return GREETING if brain.state.latest is not None else PRE_WORKOUT_GREETING


async def end_when_cap_reached(
    ctx: JobContext, session: AgentSession, seconds: int, farewell: str = SESSION_CAP_FAREWELL
) -> None:
    await asyncio.sleep(seconds)
    logger.info("session cap reached after %ds", seconds)
    with contextlib.suppress(Exception):
        handle = session.generate_reply(instructions=farewell, allow_interruptions=False)
        await asyncio.wait_for(handle.wait_for_playout(), timeout=20)
    await ctx.delete_room()
    ctx.shutdown("session cap reached")


def answer_heartbeat(_data: rtc.RpcInvocationData) -> str:
    return "pong"


def cue_writer_for(meta: SessionMeta, brain: CoachBrain, agent: CoachAgent) -> CueWriter | None:
    """The text model the phone picked for this session's cues, if the server offers it."""
    if not meta.cue_writer:
        return None
    if meta.cue_writer not in writer_models(os.environ):
        logger.warning("cue writer not offered by this server; the realtime model speaks alone")
        return None
    logger.info("cues written by %s", meta.cue_writer)
    text = TextWriter(meta.cue_writer, os.environ)
    return CueWriter(
        brain, text.write, lambda: conversation_of(agent.chat_ctx.items), close=text.aclose
    )


# The phone looks the place up with Apple Maps; that takes a few seconds on mobile data.
PLACES_TIMEOUT_S = 10.0
# The phone only kicks off the watch start and answers; the watch itself may take longer.
START_TIMEOUT_S = 5.0


async def ask_phone(
    room: rtc.Room, identity: str, method: str, payload: dict[str, Any], timeout: float
) -> dict[str, Any] | None:
    """The phone's JSON answer to an RPC, or None when it did not answer. Never raises."""
    try:
        raw = await room.local_participant.perform_rpc(
            destination_identity=identity,
            method=method,
            payload=json.dumps(payload, ensure_ascii=False),
            response_timeout=timeout,
        )
        result = json.loads(raw)
        return result if isinstance(result, dict) else None
    except Exception as e:  # an older app, no network, a slow lookup
        logger.info("%s failed: %s", method, type(e).__name__)
        return None


async def ask_phone_for_places(room: rtc.Room, identity: str, query: str) -> dict[str, Any]:
    """What is around the athlete, from their phone (spec 7.5)."""
    result = await ask_phone(room, identity, PLACES_METHOD, {"query": query}, PLACES_TIMEOUT_S)
    return result or {"available": False, "reason": "phone did not answer"}


async def ask_phone_to_start(room: rtc.Room, identity: str, activity: str) -> dict[str, Any]:
    """Has the phone start a workout on the watch (spec 7.6)."""
    result = await ask_phone(room, identity, START_METHOD, {"activity": activity}, START_TIMEOUT_S)
    return result or {"ok": False, "reason": "phone did not answer"}


async def ask_phone_to_control(room: rtc.Room, identity: str, action: str) -> dict[str, Any]:
    """Has the phone pause, resume or end the workout on the watch (spec 7.6)."""
    result = await ask_phone(room, identity, CONTROL_METHOD, {"action": action}, START_TIMEOUT_S)
    return result or {"ok": False, "reason": "phone did not answer (an app without this feature?)"}


async def ask_phone_for_history(
    room: rtc.Room, identity: str, activity: str = "", limit: int = 5
) -> dict[str, Any]:
    """Reads compact local workout history summaries from the athlete's phone (spec 11)."""
    result = await ask_phone(
        room,
        identity,
        HISTORY_METHOD,
        {"activity": activity, "limit": limit},
        START_TIMEOUT_S,
    )
    return result or {
        "available": False,
        "reason": "phone did not answer (an app without this feature?)",
    }


@server.rtc_session(agent_name=AGENT_NAME)
async def entrypoint(ctx: JobContext) -> None:
    await ctx.connect()
    ctx.room.local_participant.register_rpc_method(HEARTBEAT_METHOD, answer_heartbeat)
    inbox = AthleteInbox()
    ctx.room.on("data_received", inbox.on_data)
    participant = await ctx.wait_for_participant()
    meta = read_session_meta(participant)
    ctx.log_context_fields = {"athlete_id": meta.athlete_id, "room": ctx.room.name}

    # all coaching state is per session and per athlete (spec 3.1)
    brain = CoachBrain(Athlete(athlete_id=meta.athlete_id), tz=athlete_tz())
    inbox.attach(brain, participant.identity)

    session = AgentSession(llm=get_realtime_model(os.environ.get("COACHW_PROVIDER", "qwen")))
    directory = transcript_dir()
    history = (
        recent_conversation(
            directory,
            meta.athlete_id,
            datetime.now(UTC),
            max_age_s=HISTORY_MAX_AGE_S,
            limit=HISTORY_LINES,
        )
        if directory is not None
        else []
    )
    if history:
        logger.info("continuing the conversation from %d earlier lines", len(history))
    memory = AthleteMemory(directory, meta.athlete_id) if directory is not None else None
    if memory is not None and (saved := memory.load()):
        brain.restore_requests(saved)
        logger.info("restored %d requests the athlete made earlier", len(saved))
    agent = CoachAgent(
        brain,
        keeps_transcript=directory is not None,
        history=history,
        places=lambda query: ask_phone_for_places(ctx.room, participant.identity, query),
        start=lambda activity: ask_phone_to_start(ctx.room, participant.identity, activity),
        control=lambda action: ask_phone_to_control(ctx.room, participant.identity, action),
        workout_history=lambda activity, limit: ask_phone_for_history(
            ctx.room, participant.identity, activity, limit
        ),
        memory=memory,
    )
    turns = TurnLog()
    turns.attach(session)
    TurnGuard(session).attach()
    voice_start = VoiceStart()
    feedback = FeedbackCatcher()
    pending: set[asyncio.Task] = set()

    def run(coro: Any) -> None:
        task = asyncio.create_task(coro)
        pending.add(task)
        task.add_done_callback(pending.discard)

    def on_athlete_words(ev: Any) -> None:
        # a clear "let's start" / "pause" / product feedback works even when the model only agrees
        if not ev.is_final:
            return
        if not is_empty_turn(ev.transcript):
            brain.note_athlete_spoke()
        if (
            memory is not None
            and (note := feedback.heard(ev.transcript, time.monotonic()))
            and memory.note_feedback(note)
        ):
            logger.info("captured product feedback from athlete speech")
        if brain.workout_in_progress():
            latest = brain.state.latest
            paused = latest is not None and latest.state is WorkoutState.PAUSED
            if action := control_heard(ev.transcript, paused=paused):
                logger.info("athlete asked to %s the workout", action)
                run(agent.request_control(action))
        elif activity := voice_start.heard(ev.transcript):
            logger.info("athlete asked to start %s", activity)
            run(agent.request_start(activity))

    session.on("user_input_transcribed", on_athlete_words)
    if directory is not None:
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

    # A closed session never speaks again: leave the room instead of sitting in it silently, so
    # the phone sees the coach go and the token API does not hand the room out again (COCH-15).
    session.on("close", lambda ev: ctx.shutdown(f"agent session closed: {ev.reason}"))
    await session.start(room=ctx.room, agent=agent)
    farewell = cap_farewell(meta.max_session_s, session_max_s())
    cap = asyncio.create_task(end_when_cap_reached(ctx, session, meta.max_session_s, farewell))
    ctx.add_shutdown_callback(lambda: _cancel(cap))
    logger.info("coach session started, cap %ds", meta.max_session_s)

    # The greeting goes first: it is an `instructions=` reply, which Qwen only follows while the
    # conversation has no user turn yet, and cues are user turns (spec 4.2, 14.1).
    greeting = await greeting_for(brain, inbox)
    if history and greeting in (GREETING, PRE_WORKOUT_GREETING):
        greeting = RECONNECT_GREETING
    session.generate_reply(instructions=greeting)
    writer = cue_writer_for(meta, brain, agent)
    if writer is not None:
        brain.check_in_s = check_in_s()
    loop = CoachLoop(brain, agent, session, publish_cue, writer=writer)
    coach = asyncio.create_task(loop.run())
    ctx.add_shutdown_callback(lambda: _cancel(coach))
    refreshes: set[asyncio.Task] = set()
    ctx.add_shutdown_callback(lambda: _cancel(*refreshes))
    if writer is not None:
        ctx.add_shutdown_callback(writer.aclose)

    def on_user_state(ev: Any) -> None:
        if ev.new_state != "speaking":
            return
        task = asyncio.create_task(loop.athlete_started_speaking())
        refreshes.add(task)
        task.add_done_callback(refreshes.discard)

    session.on("user_state_changed", on_user_state)


async def _cancel(*tasks: asyncio.Task) -> None:
    for task in tasks:
        task.cancel()


def main() -> None:
    cli.run_app(server)
