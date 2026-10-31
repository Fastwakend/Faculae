import SwiftUI
import SeekCore

@MainActor
struct UsageSettingsView: View {
    let store: AppStore
    private var reported: [UsageRecord] { store.usageRecords.filter { $0.usage?.isReported == true } }
    private var estimated: [UsageRecord] { store.usageRecords.filter { $0.estimatedUnreportedOutput > 0 } }
    var body: some View {
        SettingsScaffold(title: "余额用量") {
            Form {
                Section {
                    LabeledContent("已报告 tokens", value: reported.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }.formatted())
                    LabeledContent("输入", value: reported.reduce(0) { $0 + ($1.usage?.input ?? 0) }.formatted())
                    LabeledContent("输出（含推理）", value: reported.reduce(0) { $0 + ($1.usage?.output ?? 0) }.formatted())
                    if !estimated.isEmpty {
                        LabeledContent("尚未报告的输出估算", value: "≈" + estimated.reduce(0) { $0 + $1.estimatedUnreportedOutput }.formatted())
                    }
                    LabeledContent("已记录请求", value: store.usageRecords.count.formatted())
                } header: { Text("本机累计用量") } footer: {
                    Text("每次回复后自动更新，包含重试和中断时已收到的用量。缓存 tokens 和推理 tokens 是子集，不会重复相加。未返回用量的接口仅估算输出；不包含其他客户端或升级前的消耗。删除对话不会清除累计用量。")
                }
                ForEach(store.profiles) { profile in
                    Section(profile.name) {
                        let records = store.usageRecords.filter { $0.profileID == profile.id }
                        let state = store.balances[profile.id]
                        let config = store.balanceConfigurations[profile.id] ?? BalanceConfiguration()
                        LabeledContent("已报告 tokens", value: records.reduce(0) { $0 + ($1.usage?.totalTokens ?? 0) }.formatted())
                        HStack {
                            Label("余额", systemImage: "creditcard")
                            Spacer()
                            if state?.isLoading == true { ProgressView() }
                            else { Text(state?.value.map { BalanceJSON.displayValue($0) + (config.unit.isEmpty ? "" : " " + config.unit) } ?? "未查询").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        if let date = state?.updatedAt {
                            LabeledContent("上次更新") { Text(date, style: .time).foregroundStyle(.secondary) }
                        }
                        if let error = state?.error { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) }
                        Button { Task { await store.refreshBalance(profile) } } label: {
                            Label("刷新余额", systemImage: "arrow.clockwise")
                        }
                        .disabled(config.endpoint.isEmpty || state?.isLoading == true)
                        NavigationLink {
                            BalanceConfigurationView(store: store, profile: profile, initial: config)
                        } label: {
                            Label("余额接口与自动刷新", systemImage: "slider.horizontal.3")
                        }
                    }
                }
            }
        }
    }
}

@MainActor
private struct BalanceConfigurationView: View {
    let store: AppStore
    let profile: APIProfile
    @State private var configuration: BalanceConfiguration
    @State private var minutes: String
    @State private var error: String?
    @Environment(\.dismiss) private var dismiss
    init(store: AppStore, profile: APIProfile, initial: BalanceConfiguration) {
        self.store = store; self.profile = profile
        _configuration = State(initialValue: initial)
        _minutes = State(initialValue: String(initial.refreshMinutes))
    }
    var body: some View {
        SettingsScaffold(title: "余额接口") {
            Form {
                Section {
                    TextField("API 路径，如 /user/balance", text: $configuration.endpoint)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    TextField("JSON 路径，如 data.balance", text: $configuration.jsonPath)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("余额单位，如 USD / CNY", text: $configuration.unit)
                        .autocorrectionDisabled()
                } header: { Text(profile.name) } footer: {
                    Text("使用 GET 请求，并沿用供应商 Key 与协议认证。路径可为同一域名的完整 HTTPS 地址或 / 开头的路径。JSON 路径支持 data.balance、balance_infos[0].total_balance 或 /data/balance。不同域名不会携带当前 Key。")
                }
                Section {
                    HStack {
                        Text("自动刷新间隔")
                        TextField("0", text: $minutes).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        Text("分钟").foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("0 表示仅手动刷新，范围 0–1440 分钟。自动刷新在 App 前台运行时进行，回到 App 后补查到期的余额。留空 API 路径可停用余额查询。")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
                Section {
                    Button("保存") {
                        do {
                            guard let interval = Int(minutes) else { throw APIError.provider("请输入整数分钟。") }
                            configuration.refreshMinutes = interval
                            configuration.endpoint = configuration.endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
                            try store.saveBalanceConfiguration(configuration, for: profile)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                }
            }
        }
    }
}
