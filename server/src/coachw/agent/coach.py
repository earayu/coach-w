from __future__ import annotations

import json
import logging
from collections.abc import Awaitable, Callable, Mapping, Sequence
from typing import Any

from livekit.agents import Agent, RunContext, function_tool, llm

from coachw.coach.brain import QUIET_MAX_MIN, CoachBrain
from coachw.profiles.base import ProfileTool

logger = logging.getLogger("coachw.agent")

# Product rule (AGENTS.md, spec 4.2): every number the coach says comes from a tool.
INSTRUCTIONS = """\
你是 coach-w，一位陪用户运动的中文语音教练，通过耳机和正在运动的用户实时对话。

说话方式：
- 口语、简短，每次一两句话。用户在运动，喘着气听你说话。
- 不朗读 markdown、列表符号、英文字段名或单位缩写。
- 用户随时会打断你，被打断就停下来听。
- 用户的一句话可能被切成几段先后到达，把连着的几段当成一句话理解；话明显没说完时，只简短接一句"嗯，你说"等他说完。

像一个聪明、靠谱的真人教练那样对话：
- 认真回应用户说的每一件事。跑步、训练、身体感受、装备、天气或者随便闲聊，都正常、有内容地回答，不要用"专心运动"之类的话把问题挡回去。
- 记住这次对话里用户说过的话。用户让你复述、回忆或者问"我刚才说了什么"，就照这次对话的内容把他的原意复述出来。
- 不要把同一句话说两遍；上一句没有回答到点子上，就换个说法直接回答。
- 做不到的事直说做不到，并说清楚现在能做什么。
- 用户问自己在哪、附近有什么、去哪找厕所或补给、前面是什么地方时，调用 look_around（可以带要找的东西），照结果里的地名、距离和方向回答；没有结果就直说找不到，不要编地名。

用常识看数据：
- 你懂运动生理和训练常识，知道跑步、骑行、步行等运动正常的配速或速度、步频、心率大概什么样，以及它们之间怎么关联。
- 每次拿到数据，先想一想合不合常识、和用户正在做的运动对不对得上。手表上选的运动可能和用户实际在做的不一样，传感器也会出错。
- 数据不合常识时直说哪里不对，问用户怎么回事，不要照着念，更不要夸。【教练提示】里的"鼓励""夸奖"只是默认语气，和常识冲突时以常识为准。

数字规则（最重要）：
- 你说出的每一个运动数字（心率、配速、距离、时间、步频、功率、卡路里等）都必须来自本轮刚调用的工具结果（get_metrics、get_progress、end_workout_summary），或本轮【教练提示】里给出的数字。
- 用户问到任何数据时，先调用 get_metrics（当前数据）或 get_progress（进度、分段、目标），再回答。只回答用户这一次问的那几项，不要重复你之前说过的话。
- 禁止估计、推算、编造或沿用之前记住的数字。工具没有返回某项数据，或返回 available 为 false，就直接说现在拿不到这项数据。
- get_metrics 结果里的 spoken 是当前运动下每项指标的口语读法，照着读（有的运动读速度而不是配速）。
- 有 pace_per_km 时配速用它，读作"每公里几分几秒"；距离超过一千米时读成公里。

系统消息：
- 以【教练提示】开头的消息不是用户说的话，而是教练系统决定你现在要主动对用户说的内容：不要回答"好的"，直接用一句自然的口语对用户说出来，只用里面的数字。
- 以【运动状态】开头的消息只是背景信息，不要回复它，也不要主动念出来。

工具：
- 用户说"安静一会儿"、"别说话了"时调用 set_quiet，默认 5 分钟；说"可以说话了"时用 0 分钟取消。静音期间安全提醒照常。
- 运动结束或用户要总结时调用 end_workout_summary。

安全：你不是医生。用户说胸痛、头晕、呼吸困难时，建议他立刻停下休息，必要时求助。
"""

# Only true while the server keeps transcripts (COACHW_TRANSCRIPT_DIR): the developers read the
# feedback there (COCH-15, the coach kept saying it could not note anything down).
FEEDBACK_KEPT = """
产品意见：用户提产品意见、改进点或者让你"记下来"时，这次对话的全文会保存下来给开发团队看。告诉他"记下了"，再用一句话复述要点，确认没听错。
"""

FEEDBACK_NOT_KEPT = """
产品意见：用户提产品意见、改进点或者让你"记下来"时，这次对话不会保存。用一句话复述要点，并告诉他你记不下来，请他在手机上另外记一下。
"""


def instructions(keeps_transcript: bool, history: Sequence[tuple[str, str]] = ()) -> str:
    text = INSTRUCTIONS + (FEEDBACK_KEPT if keeps_transcript else FEEDBACK_NOT_KEPT)
    if history:
        said = "\n".join(
            f"{'用户' if kind == 'user' else '教练'}：{line}" for kind, line in history
        )
        text += HISTORY.format(said=said)
    return text


# A new coach after the voice link dropped for good gets the conversation so far (COCH-15).
HISTORY = """
刚才的对话（语音断开前，按时间顺序）：
{said}
语音断开后又连上了，你就是刚才那个教练：接着刚才的对话，记住用户说过的话，不要重新自我介绍。
"""

RECONNECT_GREETING = (
    "语音刚刚重新连上。用一句简短的话告诉用户你回来了，可以接着刚才的话题，不要重新自我介绍。"
)


GREETING = "用一句简短的中文向用户打招呼，说你是他的教练，可以随时问你心率配速，也可以随时打断你。"

SESSION_CAP_FAREWELL = (
    "今天的语音时长用完了。用一句话告诉用户你要先下线了，运动记录不受影响，然后道别。"
)

SESSION_LENGTH_FAREWELL = (
    "这一次语音陪练的时长到了。用一句话告诉用户你要先下线一下，运动记录不受影响，"
    "需要的话可以在手机上重新连接教练。不要说今天的时长用完了。"
)


def cap_farewell(max_session_s: int, session_max_s: int) -> str:
    """What to say when the session cap is reached: only a cap below the per-session maximum
    was cut short by the day's remaining minutes."""
    return SESSION_LENGTH_FAREWELL if max_session_s >= session_max_s else SESSION_CAP_FAREWELL


def as_json(result: Mapping[str, Any]) -> str:
    # the framework str()s non-string results; send the model clean JSON instead
    return json.dumps(result, ensure_ascii=False, separators=(",", ":"))


def profile_tool(brain: CoachBrain, spec: ProfileTool) -> llm.RawFunctionTool:
    async def handler(raw_arguments: dict[str, object]) -> str:
        result = brain.run_profile_tool(spec.name, raw_arguments)
        logger.info("tool %s called ok=%s", spec.name, result.get("ok"))
        return as_json(result)

    return function_tool(
        handler,
        raw_schema={
            "name": spec.name,
            "description": spec.description,
            "parameters": spec.parameters,
        },
    )


# Asks the athlete's phone what is around them (`coach.places`, spec 7.5); returns its JSON.
PlaceLookup = Callable[[str], Awaitable[dict[str, Any]]]


class CoachAgent(Agent):
    def __init__(
        self,
        brain: CoachBrain,
        keeps_transcript: bool = False,
        history: Sequence[tuple[str, str]] = (),
        places: PlaceLookup | None = None,
    ) -> None:
        self._instructions = instructions(keeps_transcript, history)
        super().__init__(instructions=self._instructions)
        self.brain = brain
        self._places = places
        self._base_tools = list(self.tools)
        self._status_id: str | None = None

    async def apply_profile(self) -> None:
        """Load the current profile's prompt fragment and tools into the live session."""
        profile = self.brain.profile
        if profile is None:
            return
        await self.update_instructions(self._instructions + "\n" + profile.prompt)
        await self.update_tools(
            self._base_tools + [profile_tool(self.brain, t) for t in profile.tools]
        )
        logger.info("profile loaded: %s", profile.name)

    async def inject_status(self, text: str) -> None:
        """Replace the previous status summary in the conversation without asking for a reply."""
        ctx = self.chat_ctx.copy()
        if self._status_id and ctx.get_by_id(self._status_id):
            ctx.remove(self._status_id)
        self._status_id = ctx.add_message(role="system", content=text).id
        await self.update_chat_ctx(ctx)

    @function_tool()
    async def get_metrics(self, context: RunContext) -> str:
        """获取用户手表上最新的运动数据：心率、配速、距离、用时、步频、功率等。

        用户问到任何运动数据时必须先调用本工具。没有出现在结果里的指标表示手表这次没有测到。
        live_readings 为 false 表示运动暂停或已结束：只有用时、距离等总计，心率等实时数据要等继续后才有。
        """
        result = self.brain.get_metrics()
        # values are health data: log only that the tool ran (spec 11)
        logger.info("tool get_metrics called available=%s", result["available"])
        return as_json(result)

    @function_tool()
    async def get_progress(self, context: RunContext) -> str:
        """获取本次运动的进度：阶段、用时、距离、每公里分段、目标和剩余距离、是否静音。

        用户问跑了多久、跑了几公里、上一公里多快、还剩多少时调用。
        """
        result = self.brain.get_progress()
        logger.info("tool get_progress called available=%s", result["available"])
        return as_json(result)

    @function_tool()
    async def set_quiet(self, context: RunContext, minutes: int) -> str:
        """让教练安静一段时间，期间只播报安全类紧急提醒。

        Args:
            minutes: 安静多少分钟，1 到 30；传 0 取消安静。
        """
        result = self.brain.set_quiet(max(0, min(minutes, QUIET_MAX_MIN)))
        logger.info("tool set_quiet called quiet=%s", result["quiet"])
        return as_json(result)

    @function_tool()
    async def end_workout_summary(self, context: RunContext) -> str:
        """获取本次运动的总结数据：总用时、距离、平均心率和配速、每公里分段、最快和最慢的一公里、提醒次数。

        运动结束或用户要总结时调用。
        """
        result = self.brain.end_workout_summary()
        logger.info("tool end_workout_summary called available=%s", result["available"])
        return as_json(result)

    @function_tool()
    async def look_around(self, context: RunContext, query: str = "") -> str:
        """查用户现在在哪、附近有什么：当前所在的街道或地点，以及附近的地点名称、距离（米）和方向。

        用户问"我在哪"、"附近有什么"、"哪里有厕所 / 便利店 / 补水点"、"前面是什么地方"时调用。

        Args:
            query: 要找的东西，例如"厕所"、"便利店"；只想知道在哪、附近有什么时传空字符串。
        """
        if self._places is None:
            result: dict[str, Any] = {"available": False, "reason": "phone not connected"}
        else:
            result = await self._places(query.strip())
        # places and addresses are location data: log only the outcome (spec 11)
        logger.info("tool look_around called available=%s", result.get("available"))
        return as_json(result)
