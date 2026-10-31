import SwiftUI

@MainActor
struct BackgroundSettingsView: View {
    let store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        @Bindable var services = store.backgroundServices
        SettingsScaffold(title: "后台生成") {
            Form {
                Section {
                    SeekSwitch("切换对话时继续生成", isOn: $services.continueOnConversationSwitch)
                } footer: {
                    Text("切换到其他对话或新建对话后，原会话继续接收回复。可同时在其他对话发送消息；停止按钮只停止当前会话。离开 App 后仍受 iOS 分配的后台时间限制。")
                }
                Section {
                    SeekSwitch("后台生成", isOn: $services.backgroundEnabled)
                    LabeledContent("官方持续后台任务", value: services.runtime.continuedStatus)
                    if services.runtime.runningTaskCount > 0 || services.runtime.pendingTaskCount > 0 {
                        LabeledContent("运行中 / 等待启动", value: "\(services.runtime.runningTaskCount) / \(services.runtime.pendingTaskCount)")
                    }
                } footer: {
                    Text("在前台发送时向 iOS 26 及以上系统申请持续后台任务，以继续接收回复。系统可能显示任务进度和取消按钮；不支持或未获批准时使用短期后台时间。等待首个响应过久、资源不足或手动取消时仍可能中断，已收到的内容会保留。")
                }
                Section {
                    SeekSwitch("后台定位保活", isOn: $services.locationKeepAliveEnabled)
                        .accessibilityIdentifier("settings.background.experimental.location")
                    if services.locationKeepAliveEnabled {
                        LabeledContent("定位权限", value: services.runtime.experiments.locationAuthorization)
                        Text(services.runtime.experiments.locationStatus).font(.footnote).foregroundStyle(.secondary)
                        if services.runtime.experiments.canRequestLocation {
                            Button("申请定位权限", systemImage: "location") { services.runtime.experiments.requestLocationPermission() }
                        }
                        if services.runtime.experiments.canRequestAlwaysLocation {
                            Button("申请始终允许定位", systemImage: "location.fill") {
                                services.runtime.experiments.requestLocationPermission(always: true)
                            }
                        }
                        Button("打开系统定位设置", systemImage: "gearshape") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                        }
                    }
                    SeekSwitch("静音音频保活", isOn: $services.silentAudioKeepAliveEnabled)
                        .accessibilityIdentifier("settings.background.experimental.audio")
                    if services.silentAudioKeepAliveEnabled {
                        Text(services.runtime.experiments.audioStatus).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: { Text("实验性功能") } footer: {
                    Text("默认关闭，需同时开启后台生成。仅有回复生成时运行，最后一个任务结束后立即停止。定位会显示系统定位指示，不保存或上传坐标；静音音频会占用播放会话，来电等中断可能使其暂停。两者会增加耗电，均不能保证无限后台运行，也无法在手动划掉 App 后继续。")
                }
                Section {
                    SeekSwitch("后台任务恢复", isOn: $services.recoveryEnabled)
                } footer: {
                    Text("在系统条件允许时，向 iOS 请求刷新和处理机会，检查并保存任务进度。调度时间由系统决定；进程被终止后无法接回原来的流式连接，需返回对话手动重新生成，避免重复请求和计费。")
                }
                Section {
                    SeekSwitch("实时活动", isOn: $services.activitiesEnabled)
                    if services.activitiesEnabled {
                        LabeledContent("系统权限", value: services.activitiesAuthorized ? "已允许" : "未允许")
                        LabeledContent("更频繁更新", value: services.frequentUpdatesAllowed ? "系统已允许" : "系统未允许")
                        LabeledContent("活动数量", value: services.activeActivityCount.formatted())
                        LabeledContent("最近任务", value: services.lastReplyStatus)
                        Text(services.activityStatus).font(.footnote).foregroundStyle(.secondary)
                        if let error = services.activityError {
                            Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                        }
                        if services.canRetryActivity {
                            Button("重新启动实时活动", systemImage: "arrow.clockwise") { services.retryActivity(retryDismissed: true) }
                        }
                        if !services.activitiesAuthorized {
                            Button("打开系统设置", systemImage: "gearshape") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                        if services.isTestingActivity {
                            Button("结束显示测试", systemImage: "stop.circle") { services.stopActivityTest() }
                        } else {
                            Button("测试灵动岛与锁屏显示", systemImage: "rectangle.topthird.inset.filled") {
                                services.startActivityTest(modelName: store.selectedProfile.selectedModel.displayTitle,
                                    supplierLogo: ModelLogo.brandName(model: store.selectedProfile.model,
                                        provider: store.selectedProfile.provider, iconStyle: store.selectedProfile.selectedModel.iconStyle))
                            }
                            .disabled(store.hasActiveGenerations)
                        }
                    }
                } footer: {
                    Text("在锁屏和灵动岛显示模型、回复状态、已用时间与 tokens。显示测试不调用 API，前台约 60 秒后结束，也可手动结束。已声明更频繁更新支持，系统设置中可允许；此权限主要影响远程推送更新额度，计时由系统直接显示。≈ 表示估算用量。")
                }
                Section {
                    SeekSwitch("任务通知", isOn: $services.notificationsEnabled)
                    LabeledContent("系统权限", value: services.notificationAuthorization)
                    LabeledContent("通知横幅", value: services.notificationAlerts)
                    LabeledContent("锁屏显示", value: services.notificationLockScreen)
                    if services.canRequestNotifications {
                        Button("申请通知权限", systemImage: "bell.badge") {
                            Task { await services.requestNotificationPermission() }
                        }
                    }
                    Button("打开系统通知设置", systemImage: "gearshape") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                    }
                } footer: {
                    Text("后台回复完成或中断时发送本地通知。需要允许通知权限。")
                }
                if let notice = services.permissionNotice {
                    Section { Text(notice).font(.footnote).foregroundStyle(.secondary) }
                }
                Section {
                    SeekSwitch("记录实时活动诊断", isOn: $services.activityDiagnosticsEnabled)
                        .accessibilityIdentifier("settings.activityDiagnostics.enabled")
                    if !services.activityEvents.isEmpty {
                        Text(services.activityEvents.joined(separator: "\n"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                    } else {
                        Text(services.activityDiagnosticsEnabled ? "暂无诊断记录，等待实时活动事件。" : "诊断记录已关闭。")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ShareLink(item: services.activityEvents.joined(separator: "\n")) {
                        Label("导出诊断记录", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .seekNativeGlassButton()
                    .disabled(services.activityEvents.isEmpty)
                    Button(role: .destructive) { services.deleteActivityDiagnostics() } label: {
                        Label("删除诊断记录", systemImage: "trash")
                            .frame(maxWidth: .infinity, minHeight: 28)
                    }
                    .seekNativeGlassButton()
                    .tint(.red)
                    .disabled(services.activityEvents.isEmpty)
                    .accessibilityIdentifier("settings.activityDiagnostics.delete")
                } header: { Text("实时活动诊断") } footer: {
                    Text("默认关闭；只有开启时才记录实时活动事件，最多保留最近 16 条。关闭后保留已有记录，点击删除可清空；不影响实时活动本身。")
                }
            }
        }
        .onAppear {
            services.refreshActivityAuthorization()
            services.runtime.experiments.refreshAuthorization()
        }
        .task { await services.refreshNotificationAuthorization() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                services.refreshActivityAuthorization()
                services.runtime.experiments.refreshAuthorization()
                Task { await services.refreshNotificationAuthorization() }
            }
        }
        .onChange(of: services.notificationsEnabled) { _, enabled in
            if enabled { Task { await services.requestNotificationPermission() } }
        }
    }
}
