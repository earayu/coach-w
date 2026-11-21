# 准备清单与开发环境

写代码前需要准备好的东西。每项完成后打勾，并在 `docs/spec.md` 13.1 更新 M0 进度。

## 1. 账号与密钥

| 项 | 用途 | 需要谁做 | 状态 |
|---|---|---|---|
| Apple Developer Program（个人即可，99 美元/年） | HealthKit、watchOS App 真机调试、TestFlight | 维护者 | [x] 个人团队 `PX6VJ5XLCG`，已在本机 Xcode 登录 |
| Bundle ID 与 HealthKit 能力 | iOS `com.earayu.coachw`、手表 `com.earayu.coachw.watchkitapp` | — | [x] 2026-11-21 由自动签名注册，描述文件含 HealthKit |
| DashScope API Key（Qwen Realtime） | 服务端教练 Agent | 维护者（voicelab 已有） | [ ] |
| GitHub 仓库 `earayu/coach-w` | 代码 | — | [x] |

密钥只放在本机 `.env` 或服务器环境变量里，**不入库**。

## 2. 设备

| 项 | 要求 | 状态 |
|---|---|---|
| iPhone 16 Pro | 开启开发者模式（设置 → 隐私与安全性 → 开发者模式） | [x] |
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
| XcodeGen | `brew install xcodegen`，或下载 [release](https://github.com/yonaskolb/XcodeGen/releases) 的 `xcodegen.zip`（用包装脚本调用 `bin/xcodegen`，不要软链接，否则找不到 `share/` 里的预设） | `xcodegen --version` |
| Docker（可选，本地跑 LiveKit） | Docker Desktop | `docker --version` |

本地跑检查：

```sh
./scripts/check.sh
```

## 5. 在真机上运行（M1 验收）

1. iPhone 用数据线连 Mac，解锁并信任这台电脑；手表与 iPhone 配对、打开开发者模式（手表第一次被 Xcode 识别后，设置里才会出现开发者模式开关）。
2. `./scripts/build-apple.sh device` 生成工程，再 `open apple/CoachW.xcodeproj`。
3. Xcode 里选 scheme **CoachW**，目标选你的 iPhone，运行。手表 App 会随 iPhone App 安装；没自动装时，在 iPhone 的「Watch」App → 可用 App 里点安装，或在 Xcode 里选 scheme **CoachWWatch**、目标选手表直接运行。
4. 首次打开时两边都会请求健康权限，全部允许。
5. 在 iPhone 上选"跑步"→"在手表上开始"。手表应自动打开并开始计时，iPhone 显示实时指标和"数据流"统计。
6. 验收：锁上 iPhone 跑 1 公里，解锁后看"数据流"：丢失帧数、平均间隔（期望 ≈1 s）。把结果和 iOS / watchOS 版本记到 `docs/spec.md` 14.1。

- [ ] 确定最低部署版本（iOS / watchOS）。
