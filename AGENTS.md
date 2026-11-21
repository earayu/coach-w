# AGENTS.md

给在本仓库工作的 coding agent 的说明。

## 项目

coach-w 是一个实时语音运动教练：Apple Watch 采集运动指标，iPhone 把指标和用户的声音送到服务端的教练 Agent，教练用实时语音模型（首选 Qwen Realtime）在耳机里陪练、纠正、鼓励、聊天。跑步是主线，骑行、散步随后，其余运动由通用档案覆盖。

注意区分两个"agent"：读本文件的你是开发 coach-w 的 coding agent；文档里的"教练 Agent"指 coach-w 服务端的产品组件。

**开始任何工作前先读 [`docs/spec.md`](docs/spec.md)。** 它是产品范围、领域模型、架构和技术选型的唯一依据。准备工作和开发环境见 [`docs/setup.md`](docs/setup.md)。

## 当前状态

M1 进行中，进度见 `docs/spec.md` 13.1–13.2。已有：文档、线协议 v1（`protocol/fixtures/`、`apple/CoachKit`、`server/src/coachw/protocol.py`）、CI；iOS + watchOS App 的数据通路（手表采集 → 镜像会话 → iPhone 显示），代码完成、尚未真机验收。服务端 Agent 尚未开始。

代码地图：

- `apple/Watch/WorkoutController.swift`：手表主 workout 会话、采集、发帧
- `apple/Watch/HealthReadings.swift`：HealthKit 统计 → 线协议单位
- `apple/iOS/MirrorReceiver.swift`：iPhone 接镜像会话、解帧、统计
- `apple/Shared/WorkoutActivity.swift`：UI 可选运动与 HealthKit / 线协议的映射表、HealthKit 权限类型
- `apple/CoachKit`：`MetricsFrame`（线协议）、`FrameBuilder`（合并读数、节流、推算步频）、`FrameStats`（收端统计）

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
- 服务端：Python 3.12、uv、LiveKit Agents、`livekit-plugins-aliyun`（M2 起，版本锁定）
- 检查：Python 用 ruff + pytest；Swift 用 `swift test`
- 部署：docker compose + Caddy + LiveKit Server（M2）

## 目录约定

```text
apple/CoachKit/      SwiftPM 包：线协议、与平台无关的纯逻辑
apple/iOS/           iPhone App（M1）
apple/Watch/         watchOS App（M1）
server/src/coachw/   服务端包：protocol、agent、api、coach、profiles、providers
server/tests/        服务端测试
protocol/fixtures/   线协议规范样例，两端测试共用
deploy/              部署配置（M2）
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
