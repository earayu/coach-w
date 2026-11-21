# AGENTS.md

给在本仓库工作的 coding agent 的说明。

## 项目

coach-w 是一个实时语音运动教练：Apple Watch 采集运动指标，iPhone 把指标和用户的声音送到服务端的教练 Agent，教练用实时语音模型（首选 Qwen Realtime）在耳机里陪练、纠正、鼓励、聊天。跑步是主线，骑行、散步随后，其余运动由通用档案覆盖。

注意区分两个"agent"：读本文件的你是开发 coach-w 的 coding agent；文档里的"教练 Agent"指 coach-w 服务端的产品组件。

**开始任何工作前先读 [`docs/spec.md`](docs/spec.md)。** 它是产品范围、领域模型、架构和技术选型的唯一依据。准备工作和开发环境见 [`docs/setup.md`](docs/setup.md)。

## 当前状态

进度见 `docs/spec.md` 13.1–13.4。已有：文档、线协议 v1（`protocol/fixtures/`、`apple/CoachKit`、`server/src/coachw/protocol.py`）、CI；iOS + watchOS App 的数据通路（手表采集 → 镜像会话 → iPhone 显示），已在真机跑通，户外锁屏实测待做。M2 服务端（教练 Agent、token API、部署文件）已部署到阿里云香港 2 核 4G，公网端到端语音冒烟通过（部署与复测见 `deploy/README.md`）；iOS 已接入 LiveKit（语音、转发指标），可用 `./scripts/dev.sh --lan` 在局域网内连本机服务。M3 教练大脑（MetricsState / Director / EventEngine / CueQueue、跑步档案、教练工具、`coach.cue` 手表震动）代码完成，本机端到端冒烟通过，待真实跑步验收。M4 扩展（散步 / 徒步 / 骑行 / 通用兜底档案、跑后一句话总结、断网本机播报 + 自动重连 + `coach.resume` 续接、本机运动记录、手表 GPS 轨迹）代码完成，单元测试和本机冒烟通过，待三种运动户外实测（spec 13.5）。

代码地图：

- `apple/Watch/WorkoutController.swift`：手表主 workout 会话、采集、发帧；收 `coach.cue`、震动、表盘提示（`ContentView.swift` 的 `CueBanner`）；户外运动的 GPS 路线（`HKWorkoutRouteBuilder`）
- `apple/Watch/LocationFeed.swift`：手表定位（权限、精度过滤），坐标不打日志
- `apple/Watch/HealthReadings.swift`：HealthKit 统计 → 线协议单位
- `apple/iOS/MirrorReceiver.swift`：iPhone 接镜像会话、解帧、统计；`sendToWatch` 把 `coach.cue` 转给手表
- `apple/Shared/DesignSystem.swift`：Pulse W 暗黑运动设计系统（曜石背景渐变、电光黄绿至薄荷绿渐变、心率区间色板、`PulseWMark` 徽标、毛玻璃卡片与按钮样式）
- `apple/Shared/WorkoutActivity.swift`：UI 可选运动与 HealthKit / 线协议的映射表（含展示文案、是否开 GPS、速度读法、手机本地兜底的分段长度）、HealthKit 权限类型
- `apple/iOS/Views/`：`LobbyView`（开跑大厅、运动类型卡片选择器、语音教练预览卡与"刚刚完成"入口）、`WorkoutDashboardView`（运动仪表盘：顶部声波状态条、核心英雄卡、心率区间卡、自适应次级指标网格、折叠式数据流诊断抽屉、底部防误触控制栏）
- `apple/iOS/Components/PulseVoiceComponents.swift`：从 `VoiceSession` 派生的视图状态（`VoiceVisualState`）与动态声波动画组件（`VoiceWaveView`、`CoachStatusPill`），UI 层不接触 LiveKit 类型
- `apple/iOS/Voice/VoiceSession.swift`：唯一引用 LiveKit 的文件；连房间（带代数防 start/stop 竞态）、开麦、按序把指标帧发到 `coach.metrics`、收 `coach.cue`、跟踪教练说话态（`isCoachSpeaking`）；断线自动重连（`ReconnectPolicy` 退避 + `NWPathMonitor`）、发 `coach.resume`、收 `lk.transcription` 教练文字。`TokenClient.swift`：调 token API。`LocalSpeaker.swift`：断网时 `AVSpeechSynthesizer` 本机播报
- `apple/iOS/Records/`：`WorkoutRecorder`（跟踪当前运动、本地兜底 cue、续接摘要、结束时存记录）、`WorkoutStore`（本机 JSON 记录）、`RecordsView`（记录列表、分段柱状图与教练对话时间线详情）；接线在 `CoachWApp.swift`
- `apple/iOS/Settings/`：`AppSettings.swift`（`athlete_id`、邀请码钥匙串、token API 地址）与 `SettingsView.swift`（暗色分组设置页、服务器校验状态、邀请码显隐切换与运动者 ID 复制）
- `apple/CoachKit`：`MetricsFrame`、`CoachCue`、`CoachResume`（线协议）、`FrameBuilder`（合并读数、节流、推算步频、GPS）、`FrameStats`（收端统计）、`ServerAddress`（设置里的服务器地址校验）、`WorkoutTracker`（手机端跟踪运动：公里时刻、均值）、`LocalCoach`（断网兜底规则）、`ReconnectPolicy`、`WorkoutRecord`
- `server/src/coachw/session.py`：token API 与 Agent 的约定（Agent 名 `coach-w`、签进 token 的 `SessionMeta`）
- `server/src/coachw/agent/worker.py`：Agent 入口、`AthleteInbox`（订阅 `coach.metrics` / `coach.resume`，身份确认前暂存）、续接开场白、下发 `coach.cue`、会话时长上限；`coach.py`：系统提示词、工具、档案工具包装、状态摘要；`loop.py`：每秒教练循环（cue → `generate_reply(user_input=...)`、紧急打断、状态摘要）
- `server/src/coachw/coach/`：通用教练内核，不出现运动类型（spec 4.8）。`metrics_state.py`（窗口、连续时长、分段、基线）、`events.py`（`CoachEvent`、通用规则、`EventEngine`）、`director.py`（阶段、节点、陪伴）、`cue_queue.py`（优先级 / 冷却 / 过期 / 不插话 / 静音 / 密度）、`brain.py`（每会话编排与工具结果）、`format.py`
- `server/src/coachw/profiles/`：运动档案（spec 5.3、5.4）。`base.py`（`ActivityProfile`）、`registry.py`（`activity` → 档案）、`running.py`（P0 跑步）、`walking.py`（散步、徒步）、`cycling.py`（骑行）、`fallback.py`（通用兜底）
- `server/src/coachw/providers/`：实时模型注册表；`qwen.py` 含 `livekit-plugins-aliyun` 工具调用缺陷的绕行（spec 4.7），升级插件前先跑冒烟
- `server/src/coachw/api/`：`app.py`（`POST /v1/session`、LiveKit webhook）、`invites.py`、`quota.py`（每日分钟账本）、`tokens.py`、`config.py`（环境变量）
- `deploy/`：docker compose、Caddyfile、`livekit.yaml`（生产）/ `livekit.dev.yaml`（本机）、`.env.example`；`server/Dockerfile`

## 不可违背的产品约束

1. **手表是唯一的运动数据源。** workout 由手表的 `HKWorkoutSession` 采集和保存；iPhone 和服务端不另算一套距离、配速。服务端或语音的任何故障都不能丢运动记录。
2. **模型不猜数据。** 教练说出的每个数字都来自工具调用或注入的状态。系统提示词必须写明禁止估计数字。
3. **时机由确定性代码决定，表达交给模型。** 主动说话由 Director / EventEngine / CueQueue 决定，不让模型自己决定什么时候开口（spec 4.2）。
4. **通用内核不出现运动类型分支。** 跑步、骑行等差异只写在运动档案里（spec 第 5 节）。
5. **客户端不持有模型 Key。** iOS / watchOS 只拿服务端签发的短期 LiveKit token。
6. **健康数据最小化。** 心率、位置只在会话内存中使用；日志不打指标原值和坐标；仓库不提交真实运动记录。

改动会触及这些约束时，停下来先和维护者确认。

## 技术栈

- iOS / watchOS：Swift 6、SwiftUI、HealthKit、LiveKit Swift SDK（M2）；工程由 XcodeGen 的 `apple/project.yml` 生成（M1），`.xcodeproj` 不入库
- 共享 Swift 逻辑：SwiftPM 包 `apple/CoachKit`
- 服务端：Python 3.12、uv、`livekit-agents` / `livekit-plugins-aliyun` 1.8.10（锁定，传递依赖按 voicelab 验证过的版本约束在 `server/pyproject.toml`）、token API 用 FastAPI
- 检查：Python 用 ruff + pytest；Swift 用 `swift test`
- 部署：docker compose + Caddy + LiveKit Server v1.13.11

## 目录约定

```text
apple/CoachKit/      SwiftPM 包：线协议、与平台无关的纯逻辑
apple/iOS/           iPhone App（M1）
apple/Watch/         watchOS App（M1）
server/src/coachw/   服务端包：protocol、agent、api、coach、profiles、providers
server/tests/        服务端测试
protocol/fixtures/   线协议规范样例，两端测试共用
deploy/              部署配置：docker compose、Caddy、LiveKit
spikes/              技术验证脚本，不属于产品代码
docs/                文档
```

## 架构规则

- **HealthKit 只在 watchOS 的 workout 模块和 iOS 的镜像接收模块里被引用。** 其他代码依赖 `CoachKit` 的类型。
- **LiveKit Swift SDK 只在 iOS 的语音模块里被引用。**
- **实时模型厂商的 SDK / 插件只在 `server/src/coachw/providers/` 内被引用。** 换模型不改教练代码。
- **运动档案之外不写运动类型的 `if/switch`。** 新增运动先加档案。
- **线协议改动三处同一次提交：** `docs/spec.md` 6.3、`protocol/fixtures/`、两端的解析代码和测试。新增字段必须可缺省；破坏性改动升 `v`。
- **CoachKit 不依赖 UIKit、HealthKit、LiveKit。** 保持能在 macOS 命令行 `swift test`。
- **会过期的东西必须带过期时间。** cue、token、状态摘要都是。迟到的结果不能覆盖更新的状态。

## 工作方式

- 改动产品范围、领域模型、架构或技术选型时，先更新 `docs/spec.md`，与代码在同一次提交里。
- `docs/spec.md` 14.2 的待验证项有了实测结论后，把结论（日期、设备、系统版本）写回 14.1。
- 不凭记忆断言第三方 SDK 或平台的行为（HealthKit、LiveKit、Qwen、watchOS 后台规则尤其如此）。查当前文档或源码，或实测；未实测的写明"待验证"。
- 需要真机的验证（HealthKit、镜像会话、蓝牙耳机、户外网络）写清楚测了什么、没测什么，不把模拟器结果当真机结论。
- 新增依赖要有理由并锁定版本。
- 行为变更附带测试。教练逻辑（MetricsState、EventEngine、CueQueue、档案规则）必须能用合成指标帧做纯单元测试，不依赖真实模型。
- 参考项目的使用规则见 `docs/spec.md` 第 12 节：pace-pilot 只学思路不复制代码；从 aarc 逐字移植时保留版权头并更新 `NOTICE`。

## 提交

- 目前直接提交到 `main`。提交前 `./scripts/check.sh` 必须通过。
- 提交信息用英文，祈使句，说明做了什么和原因。
- `README.md` 和 `README_CN.md` 内容保持一致，改一份就同步另一份。
- 设计文档用中文；代码、标识符、注释、提交信息、`README.md` 用英文。
- 仓库公开：提交前确认不包含任何凭据、token、`.env`、个人数据或真实运动记录。

## 命令

```sh
./scripts/check.sh                       # 全部检查，提交前必须通过

# 服务端
cd server
uv sync                                  # 安装依赖（含 dev）
uv run ruff check . && uv run ruff format --check .
uv run pytest

# 本机起全套服务端（LiveKit 二进制 + token API + 教练 Agent，不需要 Docker）
cp .env.example .env                     # 填 DASHSCOPE_API_KEY；.env 不入库
./scripts/dev.sh                         # 日志在 logs/{livekit,api,agent}.log，Ctrl-C 全部停止
curl -X POST http://127.0.0.1:8000/v1/session -H 'Content-Type: application/json' \
  -d '{"invite_code":"dev-invite-code-01","athlete_id":"'"$(uuidgen)"'"}'

# 端到端冒烟（需要上面的服务在跑和真 Key；macOS say 提问，合成指标帧）
cd server && uv run python tests/e2e/smoke_voice.py --invite dev-invite-code-01
cd server && uv run python tests/e2e/smoke_coach.py --invite dev-invite-code-01   # M3：主动 cue、coach.cue、打断、工具
cd server && uv run python tests/e2e/smoke_m4.py --invite dev-invite-code-01      # M4：coach.resume 续接、骑行时速读法

# CoachKit
cd apple/CoachKit
swift test

# iOS + watchOS App（需要 xcodegen）
./scripts/build-apple.sh                 # 生成工程 + 模拟器构建，不签名
./scripts/build-apple.sh device          # 真机签名构建（自动签名，团队 PX6VJ5XLCG）
open apple/CoachW.xcodeproj              # 先跑过上面任一条生成工程
```

需要 macOS + Xcode（Swift 6）、uv 和 XcodeGen。`apple/CoachW.xcodeproj` 由 `project.yml` 生成，不入库，改工程只改 `project.yml`。`apple/Watch/Info.plist` 和两个 `.entitlements` 也由 XcodeGen 生成，入库是为了审阅，改动以 `project.yml` 为准。

HealthKit、镜像会话只能在真机上验证，模拟器构建通过不代表能用。

服务端说明：

- `dev.sh` 读仓库根目录的 `.env`，已在 shell 里设置的变量优先（例如 `COACHW_SESSION_MAX_MINUTES=1 ./scripts/dev.sh`）。改了 Agent 代码要重启 `dev.sh`，`dev` 模式不再自动重载。
- 找 `livekit-server` 的顺序：`LIVEKIT_SERVER_BIN`、PATH、`.tools/bin/`；都没有时 `scripts/install-livekit.sh` 从源码编译（darwin-arm64）。
- Agent 用 INFO 日志级别。DEBUG 会打印对话文本，可能包含健康数据。
- 冒烟结果写到 `artifacts/smoke_voice.json`、`artifacts/smoke_coach.json`、`artifacts/smoke_m4.json`（不入库）。改提示词、工具、教练编排或升级 LiveKit / 插件后要跑一遍，并把结论写进 spec 14.1。
- 教练逻辑的单元测试用 `server/tests/synth.py` 的合成跑步（`Clock`、`Runner`），不依赖模型。手机端跟踪 / 兜底规则的测试用 `apple/CoachKit/Tests/CoachKitTests/Synth.swift`。
- 开场白必须在 `CoachLoop` 启动前发出：它用 `instructions=`，会话里已有用户消息（cue）后 Qwen 不理会（spec 4.8）。
- 本机没有 `livekit-server` 时可用 `LIVEKIT_SERVER_BIN=<路径> ./scripts/dev.sh`；Xcode 下载 LiveKit 包超时时可把别的检出里的 `.build/DerivedData/SourcePackages` 用 `cp -cR` 克隆过来。
- Qwen 会忽略会话中途的 system 消息：要让模型主动说的话用 `generate_reply(user_input=...)`（spec 4.2、14.1）。
- 部署步骤见 `deploy/README.md`。
