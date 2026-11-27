import CoachKit
import SwiftUI
import UIKit

/// Settings as a plain iOS form: server, invite code, athlete ID, developer options, diagnostics.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var showInviteCode = false
    @State private var copiedAthleteID = false
    @State private var providerCatalog: ProviderCatalog?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("服务器") {
                        TextField("", text: $settings.apiBaseURL, prompt: Text(verbatim: "https://coach.apemind.ai"))
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("邀请码") {
                        HStack(spacing: 8) {
                            Group {
                                if showInviteCode {
                                    TextField("", text: $settings.inviteCode, prompt: Text("必填"))
                                } else {
                                    SecureField("", text: $settings.inviteCode, prompt: Text("必填"))
                                }
                            }
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .multilineTextAlignment(.trailing)
                            Button {
                                showInviteCode.toggle()
                            } label: {
                                Image(systemName: showInviteCode ? "eye.slash" : "eye")
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel(showInviteCode ? "隐藏邀请码" : "显示邀请码")
                        }
                    }
                } header: {
                    Text("语音教练")
                } footer: {
                    Text(serverFooter)
                        .foregroundStyle(serverFooterIsError ? Theme.red : Theme.secondaryText)
                }

                Section {
                    Toggle("运动开始时接通教练", isOn: $settings.coachJoinsWorkouts)
                } footer: {
                    Text("在手机或手表上开始运动，教练就自动接通；运动结束后陪你复盘，安静 2 分钟后自己挂断。关掉后只由手表记录和震动，需要时在首页点「和教练聊聊」。")
                }

                Section {
                    Button {
                        UIPasteboard.general.string = settings.athleteID
                        copiedAthleteID = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.8))
                            copiedAthleteID = false
                        }
                    } label: {
                        LabeledContent {
                            Image(systemName: copiedAthleteID ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copiedAthleteID ? Theme.green : Theme.secondaryText)
                        } label: {
                            Text(settings.athleteID)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                } header: {
                    Text("运动者 ID")
                } footer: {
                    Text("首次安装时随机生成，只用来区分会话，不含姓名。点按复制。")
                }

                Section {
                    Picker("实时语音模型", selection: $settings.voiceProvider) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("服务器默认")
                            Text(defaultProviderDetail)
                                .font(.caption)
                                .foregroundStyle(Theme.secondaryText)
                        }
                        .tag("")
                        ForEach(displayedProviders) { provider in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(provider.title)
                                    if let badge = provider.statusBadge {
                                        Text(badge)
                                            .font(.caption2)
                                            .foregroundStyle(provider.configured == true ? Theme.green : Theme.secondaryText)
                                    }
                                }
                                Text(provider.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .tag(provider.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("实时语音模型")
                } footer: {
                    Text("切换后，断开语音并重新连接即生效。模型 Key 仅保存在服务端，不在手机端存放。OpenRouter 暂不提供 /v1/realtime，选它时服务端用 OpenRouter Key 跑 STT + LLM + TTS。")
                }

                Section {
                    Picker("主动播报", selection: $settings.cueWriter) {
                        ForEach(AppSettings.cueWriters, id: \.id) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.title)
                                Text(option.detail)
                                    .font(.caption)
                                    .foregroundStyle(Theme.secondaryText)
                            }
                            .tag(option.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    Text("开发者选项")
                } footer: {
                    Text("「先写稿」：每条主动播报先由文本模型结合常识和最近的对话写好，再由语音模型说出；安全提醒不经过它。你提问时仍由语音模型直接回答。断开语音后重新连接生效。")
                }

                Section {
                    ShareLink(item: Diagnostics.shared.contents(), preview: SharePreview("coach-w 诊断日志")) {
                        Label("分享诊断日志", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text("记录按钮点击、运动与语音状态的变化，用于排查「点了没反应」。不含心率、位置和对话内容。")
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.canvas)
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        settings.normalize()
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .task(id: "\(settings.apiBaseURL.trimmedForSettings)|\(settings.trimmedInviteCode)") {
            guard settings.isConfigured else {
                providerCatalog = nil
                return
            }
            providerCatalog = try? await TokenClient.fetchProviders(
                baseURL: settings.apiBaseURL, inviteCode: settings.trimmedInviteCode
            )
        }
    }

    private struct DisplayedProvider: Identifiable {
        let id: String
        let title: String
        let detail: String
        let configured: Bool?
        let statusBadge: String?
    }

    private var defaultProviderDetail: String {
        if let def = providerCatalog?.defaultProvider, !def.isEmpty {
            return "当前服务端默认：\(def)"
        }
        return "跟随服务端 COACHW_PROVIDER（默认 Qwen Realtime）"
    }

    private var displayedProviders: [DisplayedProvider] {
        if let catalog = providerCatalog, !catalog.providers.isEmpty {
            return catalog.providers.map { p in
                DisplayedProvider(
                    id: p.id,
                    title: p.title,
                    detail: p.detail,
                    configured: p.configured,
                    statusBadge: p.configured ? "可用" : (p.missingEnv.isEmpty ? "未配置" : "缺 \(p.missingEnv)")
                )
            }
        }
        return AppSettings.voiceProviders.map { p in
            DisplayedProvider(id: p.id, title: p.title, detail: p.detail, configured: nil, statusBadge: nil)
        }
    }

    private var serverFooterIsError: Bool {
        let trimmed = settings.apiBaseURL.trimmedForSettings
        return !trimmed.isEmpty && ServerAddress.parse(trimmed) == nil
    }

    private var serverFooter: String {
        let trimmed = settings.apiBaseURL.trimmedForSettings
        if serverFooterIsError { return "服务器地址格式不对，应以 https:// 或 http:// 开头。" }
        if !trimmed.isEmpty, ServerAddress.parse(trimmed)?.scheme?.lowercased() == "http" {
            return "正在用局域网 HTTP 地址，仅限本地开发。邀请码保存在本机钥匙串。"
        }
        return "正式环境填 https 域名，本地开发填 Mac 的局域网地址。邀请码保存在本机钥匙串，不写入日志。"
    }
}
