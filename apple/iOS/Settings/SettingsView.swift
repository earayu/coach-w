import CoachKit
import SwiftUI
import UIKit

/// Obsidian Pulse W settings sheet: server validation status, masked invite code, and copyable athlete ID.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showInviteCode = false
    @State private var copiedAthleteID = false

    var body: some View {
        NavigationStack {
            ZStack {
                PulseBackground(auraOpacity: 0.10)

                ScrollView {
                    VStack(spacing: 16) {
                        readinessCard
                        serverCard
                        inviteCodeCard
                        athleteIDCard
                        diagnosticsCard
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 32)
                }
                .scrollIndicators(.hidden)
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") {
                        settings.normalize()
                        dismiss()
                    }
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(PulseTheme.volt)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private var readinessCard: some View {
        let ready = settings.isConfigured
        let accent = ready ? PulseTheme.mint : PulseTheme.amber
        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.18))
                    .frame(width: 40, height: 40)
                Image(systemName: ready ? "checkmark.seal.fill" : "exclamationmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(accent)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(ready ? "语音教练已就绪" : "还差一步完成配置")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Text(ready ? "返回主页即可一键连接实时语音教练" : "请填写有效的服务器地址与邀请码")
                    .font(.caption)
                    .foregroundStyle(PulseTheme.textSecondary)
            }
            Spacer()
        }
        .padding(14)
        .pulseCard(highlighted: ready, cornerRadius: 18)
    }

    private var serverCard: some View {
        let state = serverValidation
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("服务器地址", systemImage: "network")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                HStack(spacing: 5) {
                    Circle()
                        .fill(state.color)
                        .frame(width: 7, height: 7)
                    Text(state.label)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(state.color)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(state.color.opacity(0.14), in: Capsule())
            }

            TextField(
                "",
                text: $settings.apiBaseURL,
                prompt: Text("https://coach.apemind.ai").foregroundStyle(PulseTheme.textTertiary)
            )
            .keyboardType(.URL)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(.subheadline.monospaced())
            .foregroundStyle(PulseTheme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(PulseTheme.obsidianMid.opacity(0.75), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(state.borderColor, lineWidth: 1)
            )

            Text(verbatim: "正式环境填 https 域名（例如 https://coach.apemind.ai），本地开发填 Mac 局域网地址。")
                .font(.caption)
                .foregroundStyle(PulseTheme.textTertiary)
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private var inviteCodeCard: some View {
        let filled = !settings.trimmedInviteCode.isEmpty
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("邀请码", systemImage: "key.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                Text(filled ? "已填写" : "必填")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(filled ? PulseTheme.mint : PulseTheme.textTertiary)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        (filled ? PulseTheme.mint.opacity(0.14) : PulseTheme.obsidianMid.opacity(0.6)),
                        in: Capsule()
                    )
            }

            HStack(spacing: 10) {
                Group {
                    if showInviteCode {
                        TextField(
                            "",
                            text: $settings.inviteCode,
                            prompt: Text("输入邀请码").foregroundStyle(PulseTheme.textTertiary)
                        )
                    } else {
                        SecureField(
                            "",
                            text: $settings.inviteCode,
                            prompt: Text("输入邀请码").foregroundStyle(PulseTheme.textTertiary)
                        )
                    }
                }
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .font(.subheadline.monospaced())
                .foregroundStyle(PulseTheme.textPrimary)

                Button {
                    showInviteCode.toggle()
                } label: {
                    Image(systemName: showInviteCode ? "eye.slash.fill" : "eye.fill")
                        .font(.subheadline)
                        .foregroundStyle(PulseTheme.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(showInviteCode ? "隐藏邀请码" : "显示邀请码")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PulseTheme.obsidianMid.opacity(0.75), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(PulseTheme.surfaceStroke, lineWidth: 1)
            )

            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                    .font(.caption2)
                    .foregroundStyle(PulseTheme.mint)
                Text("邀请码加密保存在本机 iOS 钥匙串，不写入日志。")
                    .font(.caption)
                    .foregroundStyle(PulseTheme.textTertiary)
            }
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private var athleteIDCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("运动者 ID", systemImage: "person.text.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                Button {
                    UIPasteboard.general.string = settings.athleteID
                    withAnimation(.spring(duration: 0.25)) {
                        copiedAthleteID = true
                    }
                    Task {
                        try? await Task.sleep(for: .seconds(1.8))
                        withAnimation(.easeOut(duration: 0.2)) {
                            copiedAthleteID = false
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: copiedAthleteID ? "checkmark" : "doc.on.doc")
                            .font(.caption2.weight(.bold))
                        Text(copiedAthleteID ? "已复制" : "复制")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(copiedAthleteID ? PulseTheme.obsidianMid : PulseTheme.volt)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 5)
                    .background(
                        copiedAthleteID ? PulseTheme.mint : PulseTheme.volt.opacity(0.14),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
            }

            Text(settings.athleteID)
                .font(.footnote.monospaced())
                .foregroundStyle(PulseTheme.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(PulseTheme.obsidianMid.opacity(0.75), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

            Text("首次安装随机生成的匿名标识，仅用于服务端区分会话，不含个人姓名。")
                .font(.caption)
                .foregroundStyle(PulseTheme.textTertiary)
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private var diagnosticsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("诊断日志", systemImage: "doc.text.magnifyingglass")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(PulseTheme.textPrimary)
                Spacer()
                ShareLink(item: Diagnostics.shared.contents(), preview: SharePreview("coach-w 诊断日志")) {
                    Label("分享", systemImage: "square.and.arrow.up")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(PulseTheme.volt)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(PulseTheme.volt.opacity(0.14), in: Capsule())
                }
                .buttonStyle(.plain)
            }
            Text("记录按钮点击、运动与语音状态的变化，用于排查「点了没反应」。不含心率、位置和对话内容。")
                .font(.caption)
                .foregroundStyle(PulseTheme.textTertiary)
        }
        .padding(16)
        .pulseCard(cornerRadius: 20)
    }

    private var serverValidation: (label: String, color: Color, borderColor: Color) {
        let trimmed = settings.apiBaseURL.trimmedForSettings
        if trimmed.isEmpty {
            return ("待填写", PulseTheme.textTertiary, PulseTheme.surfaceStroke)
        }
        if let url = ServerAddress.parse(trimmed) {
            if url.scheme?.lowercased() == "https" {
                return ("HTTPS 就绪", PulseTheme.mint, PulseTheme.mint.opacity(0.42))
            }
            return ("局域网 HTTP", PulseTheme.amber, PulseTheme.amber.opacity(0.42))
        }
        return ("地址格式无效", PulseTheme.coral, PulseTheme.coral.opacity(0.55))
    }
}
