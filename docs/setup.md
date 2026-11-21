# 准备清单与开发环境

写代码前需要准备好的东西。每项完成后打勾，并在 `docs/spec.md` 13.1 更新 M0 进度。

## 1. 账号与密钥

| 项 | 用途 | 需要谁做 | 状态 |
|---|---|---|---|
| Apple Developer Program（个人即可，99 美元/年） | HealthKit、watchOS App 真机调试、TestFlight | 维护者 | [ ] |
| 选定 Bundle ID 前缀（如 `com.<you>.coachw`），在开发者后台开启 HealthKit 能力 | iOS App、watchOS App 两个 target | 维护者 | [ ] |
| DashScope API Key（Qwen Realtime） | 服务端教练 Agent | 维护者（voicelab 已有） | [ ] |
| GitHub 仓库 `earayu/coach-w` | 代码 | — | [x] |

密钥只放在本机 `.env` 或服务器环境变量里，**不入库**。

## 2. 设备

| 项 | 要求 | 状态 |
|---|---|---|
| iPhone 16 Pro | 开启开发者模式（设置 → 隐私与安全性 → 开发者模式） | [ ] |
| Apple Watch SE（第二代） | 与 iPhone 配对；开启开发者模式（手表上 设置 → 隐私与安全性 → 开发者模式，需先在 Xcode 中连接过） | [ ] |
| 记录系统版本 | iOS ____ / watchOS ____（决定最低部署版本，见 spec 第 15 节） | [ ] |
| 韶音耳机 | 与 iPhone 配对 | [ ] |

## 3. 服务器与域名（M2 前）

| 项 | 要求 | 状态 |
|---|---|---|
| 云主机 | 2 核 4G 起，公网 IP；地域见 spec 第 10 节（未备案选香港） | [ ] |
| 域名 | 一个子域名，如 `coach.example.com`，A 记录指向主机 | [ ] |
| 安全组 | 放通 443/TCP、7881/TCP、3478/UDP、50000–60000/UDP（部署时以 LiveKit 文档核对） | [ ] |
| SSH 访问 | coding agent 部署用的 SSH 密钥 | [ ] |

## 4. 本机开发环境

| 工具 | 安装 | 检查 |
|---|---|---|
| Xcode（含 Swift 6） | App Store | `xcodebuild -version` |
| uv | `curl -LsSf https://astral.sh/uv/install.sh \| sh` | `uv --version` |
| XcodeGen（M1 起） | `brew install xcodegen` | `xcodegen --version` |
| Docker（可选，本地跑 LiveKit） | Docker Desktop | `docker --version` |

本地跑检查：

```sh
./scripts/check.sh
```

## 5. M1 开工前要确认的

- [ ] 下载 Apple 示例 "Building a multidevice workout app"，确认其 LICENSE，决定复制哪些文件进 `apple/iOS`、`apple/Watch`。
- [ ] 用示例原样在真机上跑通一次镜像（不改代码），记录到 spec 14.1。
- [ ] 确定最低部署版本（iOS / watchOS）。
