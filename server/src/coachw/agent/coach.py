from __future__ import annotations

import json
import logging

from livekit.agents import Agent, RunContext, function_tool

from coachw.agent.metrics import LatestMetrics

logger = logging.getLogger("coachw.agent")

# Product rule (AGENTS.md, spec 4.2): every number the coach says comes from a tool.
INSTRUCTIONS = """\
你是 coach-w，一位陪用户运动的中文语音教练，通过耳机和正在运动的用户实时对话。

说话方式：
- 口语、简短，每次一两句话。用户在运动，喘着气听你说话。
- 不朗读 markdown、列表符号、英文字段名或单位缩写。
- 用户随时会打断你，被打断就停下来听。

数字规则（最重要）：
- 你说出的每一个运动数字（心率、配速、距离、时间、步频、功率、卡路里等）都必须来自本轮刚调用的 get_metrics 工具结果。
- 用户问到任何数据时，先调用 get_metrics，再回答。只回答用户这一次问的那几项，不要重复你之前说过的话。
- 禁止估计、推算、编造或沿用之前记住的数字。工具没有返回某项数据，或返回 available 为 false，就直接说现在拿不到这项数据。
- 配速用工具里的 pace_per_km，读作"每公里几分几秒"；距离超过一千米时读成公里。

安全：你不是医生。用户说胸痛、头晕、呼吸困难时，建议他立刻停下休息，必要时求助。
"""

GREETING = "用一句简短的中文向用户打招呼，说你是他的教练，可以随时问你心率配速，也可以随时打断你。"

SESSION_CAP_FAREWELL = (
    "今天的语音时长用完了。用一句话告诉用户你要先下线了，运动记录不受影响，然后道别。"
)


class CoachAgent(Agent):
    def __init__(self, metrics: LatestMetrics) -> None:
        super().__init__(instructions=INSTRUCTIONS)
        self._metrics = metrics

    @function_tool()
    async def get_metrics(self, context: RunContext) -> str:
        """获取用户手表上最新的运动数据：心率、配速、距离、用时、步频、功率等。

        用户问到任何运动数据时必须先调用本工具。没有出现在结果里的指标表示手表这次没有测到。
        """
        result = self._metrics.snapshot()
        # values are health data: log only that the tool ran (spec 11)
        logger.info("tool get_metrics called available=%s", result["available"])
        # the framework str()s non-string results; send the model clean JSON instead
        return json.dumps(result, ensure_ascii=False, separators=(",", ":"))
