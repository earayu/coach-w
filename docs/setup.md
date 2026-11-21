# 准备清单与开发环境

写代码前需要准备好的东西。每项完成后打勾，并在 `docs/spec.md` 13.1 更新 M0 进度。

## 1. 账号与密钥

| 项 | 用途 | 需要谁做 | 状态 |
|---|---|---|---|
| Apple Developer Program（个人即可，99 美元/年） | HealthKit、watchOS App 真机调试、TestFlight | 维护者 | [x] 个人团队 `PX6VJ5XLCG`，已在本机 Xcode 登录 |
| Bundle ID 与 HealthKit 能力 | iOS `com.earayu.coachw`、手表 `com.earayu.coachw.watchkitapp` | — | [x] 2026-11-21 由自动签名注册，描述文件含 HealthKit |
| DashScope API Key（Qwen Realtime） | 服务端教练 Agent | 维护者（voicelab 已有） | [x] 2026-11-21 本机冒烟用过（放在本机 `.env`）；部署时放进服务器的 `deploy/.env` |
| GitHub 仓库 `earayu/coach-w` | 代码 | — | [x] |

密钥只放在本机 `.env` 或服务器环境变量里，**不入库**。

## 2. 设备

| 项 | 要求 | 状态 |
|---|---|---|
| iPhone 16 Pro | 开启开发者模式（设置 → 隐私与安全性 → 开发者模式） | [x] |
| Apple Watch Series 8（watchOS 26.6.1） | 与 iPhone 配对；开启开发者模式（见第 5 节的坑） | [x] |
| 记录系统版本 | iOS 27.2.1 / watchOS 26.6.1 | [x] |
| 韶音耳机 | 与 iPhone 配对 | [ ] |

## 3. 服务器与域名（M2 前）

| 项 | 要求 | 状态 |
|---|---|---|
| 云主机 | 2 核 4G 起，公网 IP；地域见 spec 第 10 节（未备案选香港）。已用阿里云香港 2 核 4G、Ubuntu 24.04 | [x] |
| 域名 | 一个子域名，如 `coach.example.com`，A 记录指向主机（Cloudflare 只做 DNS，不开代理） | [x] |
| 安全组 | 放通 80/TCP、443/TCP、7881/TCP、50000–60000/UDP（已按 LiveKit 文档核对，见 spec 第 10 节和 `deploy/README.md`） | [x] |
| SSH 访问 | coding agent 部署用的 SSH 密钥 | [x] |

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

1. iPhone 用数据线连 Mac，解锁并信任这台电脑；手表与 iPhone 配对、打开开发者模式。watchOS 26 及更早：
   - 手表经由连线的 iPhone 被 Mac 发现，手表上会弹"信任这台电脑"，要在约 3 分钟内点信任（手表需解锁）。`xcrun devicectl list devices` 里出现手表且为 `available (paired)` 即配对成功。
   - 配对后设置里可能仍没有开发者模式。向手表装一次开发版 App 就会出现：`xcrun devicectl device install app --device <手表UDID> <CoachWWatch.app>`（会因未开启开发者模式失败，这是预期的）。
   - watchOS 27 走 Device Hub（Xcode → Open Developer Tool → Device Hub → + → Pair Nearby Device…）。
   - 新设备第一次安装若报"This provisioning profile cannot be installed on this device"，以该设备为目标带 `-allowProvisioningDeviceRegistration` 构建一次，注册设备 UDID。
2. `./scripts/build-apple.sh device` 生成工程，再 `open apple/CoachW.xcodeproj`。
3. Xcode 里选 scheme **CoachW**，目标选你的 iPhone，运行。手表 App 会随 iPhone App 安装；没自动装时，在 iPhone 的「Watch」App → 可用 App 里点安装，或在 Xcode 里选 scheme **CoachWWatch**、目标选手表直接运行。
4. 首次打开时两边都会请求健康权限，全部允许。
5. 在 iPhone 上选"跑步"→"在手表上开始"。手表应自动打开并开始计时，iPhone 显示实时指标和"数据流"统计。
6. 验收：锁上 iPhone 跑 1 公里，解锁后看"数据流"：丢失帧数、平均间隔（期望 ≈1 s）。把结果和 iOS / watchOS 版本记到 `docs/spec.md` 14.1。

- [ ] 确定最低部署版本（iOS / watchOS）。

## 6. 在局域网里和教练对话（M2，不需要服务器）

1. `.env` 里填好 `DASHSCOPE_API_KEY` 和 `COACHW_INVITES`（见 `.env.example`）。
2. `./scripts/dev.sh --lan`：输出里的 Token API 地址形如 `http://192.168.x.x:8000`。手机和 Mac 必须连同一个 Wi‑Fi，Mac 防火墙要放行 7880、7881/TCP、7882/UDP、8000/TCP。
3. iPhone 的 coach-w →右上角"设置"：邀请码填 `COACHW_INVITES` 里的 code，服务器地址填上一步的地址（不带 `/v1/session`）。第一次连接会弹"本地网络"和"麦克风"权限，都允许。
4. 首页"语音教练"→"连接教练"，状态变成"已连接教练"后就可以说话。开始一次运动后，"已发送指标"会每秒增加，这时可以问"我现在心率多少"。

### LiveKit 二进制包下载超时

LiveKit Swift SDK 依赖约 690 MB 的 WebRTC 二进制包，xcodebuild 下载会在国内网络下超时（`downloadError("The request timed out.")`）。手动断点续传后放进 SwiftPM 缓存：

```sh
mkdir -p ~/Library/Caches/org.swift.swiftpm/artifacts && cd ~/Library/Caches/org.swift.swiftpm/artifacts
u=https://github.com/livekit/webrtc-xcframework/releases/download/150.7871.04/LiveKitWebRTC.xcframework.zip
until curl -fL -C - -o https___github_com_livekit_webrtc_xcframework_releases_download_150_7871_04_LiveKitWebRTC_xcframework_zip "$u"; do sleep 2; done
```

缓存文件名是 URL 里的 `:`、`/`、`.`、`-` 都换成 `_`。版本号以 `apple/project.yml` 锁定的 LiveKit 版本所依赖的 `webrtc-xcframework` 为准。

