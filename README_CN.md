# coach-w

[English](README.md)

一个一直在你身边的实时语音运动教练。Apple Watch 看着你的身体，耳机里有人陪你说话。

戴上 Apple Watch、带上 iPhone、戴上耳机（首先支持骨传导）出门运动。手表实时采集心率、配速、步频、功率和跑姿，iPhone 把这些指标和你的声音一起送到服务端的教练 Agent，教练通过实时语音模型（首选 Qwen Realtime）说话：提醒、纠正、鼓励、聊天，你随时可以打断它。

跑步优先，然后是骑行和散步（散步时它更像一个聊天伙伴而不是教练）。Apple Watch 支持的其他运动由通用档案覆盖。

> 状态：M0 准备中，还不能运行。见 [`docs/spec.md`](docs/spec.md)。

## 工作方式

```
Apple Watch（watchOS App）   HKWorkoutSession、实时指标、震动
        │ 镜像 workout 会话
iPhone（iOS App）            音频会话、LiveKit 客户端、断网兜底播报
        │ WebRTC（音频 + data channel）
服务端                        LiveKit Server + 教练 Agent（Python，LiveKit Agents）
        │
Qwen Realtime（DashScope）
```

- **手表是唯一的运动数据源。** 服务端或网络故障不会丢运动记录。
- **模型不猜数字。** 教练说出的每个数字都来自工具调用或注入的状态。
- **代码决定什么时候说，模型决定怎么说。** 导演、事件引擎和提示队列（优先级、冷却、过期、不打断用户）挑选时机；实时模型把每条提示说成自然的话。
- **一个内核，多个运动档案。** `profiles/` 之外不写运动类型分支。

## 仓库结构

```
apple/CoachKit/     Swift 包：线协议和与平台无关的逻辑
apple/iOS, Watch/   iPhone 和 watchOS App（M1）
server/             Python：教练 Agent、token API、运动档案
protocol/fixtures/  线协议规范样例，两端共用
deploy/             LiveKit + Agent 的 docker compose（M2）
docs/               设计文档和准备清单
```

## 开发

需要 macOS + Xcode（Swift 6）和 [uv](https://docs.astral.sh/uv/)。

```sh
./scripts/check.sh
```

需要准备的账号、设备和服务器见 [`docs/setup.md`](docs/setup.md)，贡献规则见 [`AGENTS.md`](AGENTS.md)。

## 许可

[Apache-2.0](LICENSE)
