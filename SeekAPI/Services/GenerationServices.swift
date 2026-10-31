import ActivityKit
import BackgroundTasks
import Observation
import UIKit
import UserNotifications
import OSLog

@MainActor
private final class LiveReplySession {
    let attributes: ReplyActivityAttributes
    var state = ReplyActivityAttributes.ContentState(status: "正在接收回复", tokens: 0, estimated: true)
    var activity: Activity<ReplyActivityAttributes>?
    var update: Task<Void, Never>?
    var monitor: Task<Void, Never>?
    var lastUpdate = Date.distantPast
    var dismissed = false
    var wasBackgrounded = false
    init(_ attributes: ReplyActivityAttributes) { self.attributes = attributes }
}

@MainActor
@Observable
final class GenerationServices {
    static let shared = GenerationServices()
    static let refreshID = "app.seekapi.ios.reply.refresh"
    static let processingID = "app.seekapi.ios.reply.processing"

    var backgroundEnabled = UserDefaults.standard.object(forKey: "generation.background") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(backgroundEnabled, forKey: "generation.background")
            configureBackgroundRuntime()
        }
    }
    var locationKeepAliveEnabled = UserDefaults.standard.bool(forKey: "generation.experimental.location") {
        didSet {
            UserDefaults.standard.set(locationKeepAliveEnabled, forKey: "generation.experimental.location")
            if locationKeepAliveEnabled { runtime.experiments.requestLocationPermission() }
            configureBackgroundRuntime()
        }
    }
    var silentAudioKeepAliveEnabled = UserDefaults.standard.bool(forKey: "generation.experimental.audio") {
        didSet {
            UserDefaults.standard.set(silentAudioKeepAliveEnabled, forKey: "generation.experimental.audio")
            configureBackgroundRuntime()
        }
    }
    var continueOnConversationSwitch = UserDefaults.standard.object(forKey: "generation.continueOnSwitch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(continueOnConversationSwitch, forKey: "generation.continueOnSwitch") }
    }
    var recoveryEnabled = UserDefaults.standard.bool(forKey: "generation.recovery") {
        didSet {
            UserDefaults.standard.set(recoveryEnabled, forKey: "generation.recovery")
            if !recoveryEnabled { cancelScheduledWork() }
        }
    }
    var activitiesEnabled = UserDefaults.standard.object(forKey: "generation.activities") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(activitiesEnabled, forKey: "generation.activities")
            if activitiesEnabled { retryActivity(retryDismissed: true) }
            else {
                stopActivityTest()
                for session in sessions.values { endActivity(session, status: "实时活动已关闭") }
                recordActivity("实时活动已关闭")
            }
        }
    }
    var notificationsEnabled = UserDefaults.standard.bool(forKey: "generation.notifications") {
        didSet { UserDefaults.standard.set(notificationsEnabled, forKey: "generation.notifications") }
    }
    var activityDiagnosticsEnabled = UserDefaults.standard.bool(forKey: "generation.activityDiagnostics") {
        didSet { UserDefaults.standard.set(activityDiagnosticsEnabled, forKey: "generation.activityDiagnostics") }
    }
    private(set) var permissionNotice: String?
    private(set) var notificationAuthorization = "正在检查"
    private(set) var notificationAlerts = "正在检查"
    private(set) var notificationLockScreen = "正在检查"
    private(set) var canRequestNotifications = false
    private(set) var activitiesAuthorized = ActivityAuthorizationInfo().areActivitiesEnabled
    private(set) var frequentUpdatesAllowed = ActivityAuthorizationInfo().frequentPushesEnabled
    private(set) var activityStatus = "等待生成任务"
    private(set) var lastReplyStatus = "暂无任务"
    private(set) var activityError: String?
    private(set) var activityEvents = UserDefaults.standard.stringArray(forKey: "generation.activityEvents") ?? []
    private var sessions: [UUID: LiveReplySession] = [:]
    private var testReplyID: UUID?
    var isTestingActivity: Bool { testReplyID != nil }
    var canRetryActivity: Bool { activitiesEnabled && sessions.values.contains { $0.activity == nil } }
    var activeActivityCount: Int { sessions.values.filter { $0.activity != nil }.count }
    let runtime = ReplyBackgroundRuntime()
    @ObservationIgnored var onExpiration: ((String) -> Void)?
    @ObservationIgnored var onReplyExpiration: ((UUID, String) -> Void)?
    @ObservationIgnored var onCheckpoint: (() -> Void)?
    @ObservationIgnored var isGenerating: (() -> Bool)?
    @ObservationIgnored private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    @ObservationIgnored private var shortTaskToken: UUID?
    @ObservationIgnored private var scheduledGrants: Set<UUID> = []
    @ObservationIgnored private var isInBackground = false
    @ObservationIgnored private var authorizationMonitor: Task<Void, Never>?
    @ObservationIgnored private var testTask: Task<Void, Never>?
    @ObservationIgnored private let activityLog = Logger(subsystem: "app.seekapi.ios", category: "LiveActivity")
    @ObservationIgnored private var registered = false

    func registerTasks() {
        guard !registered else { return }
        registered = true
        runtime.onReplyExpiration = { [weak self] id, reason in
            self?.onCheckpoint?()
            self?.onReplyExpiration?(id, reason)
        }
        runtime.onExecutionChanged = { [weak self] in
            self?.stopUnprotectedReplies(reason: "可用后台执行时间已结束，已保留收到的内容")
        }
        configureBackgroundRuntime()
        authorizationMonitor = Task { [weak self] in
            for await allowed in ActivityAuthorizationInfo().activityEnablementUpdates {
                guard let self else { return }
                self.activitiesAuthorized = allowed
                if allowed { self.retryActivity() }
                else { self.recordActivity("系统未允许实时活动") }
            }
        }
        for id in [Self.refreshID, Self.processingID] {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: id, using: .main) { [weak self] task in
                Task { @MainActor in self?.handleScheduled(task) }
            }
        }
    }

    func refreshActivityAuthorization() {
        let info = ActivityAuthorizationInfo()
        activitiesAuthorized = info.areActivitiesEnabled
        frequentUpdatesAllowed = info.frequentPushesEnabled
    }

    func requestNotificationPermission() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            if allowed { permissionNotice = nil }
            else { permissionNotice = "通知权限未开启，请在系统设置中允许 Faculae 发送通知。" }
        } catch { permissionNotice = "暂时无法申请通知权限，请在系统设置中检查。" }
        await refreshNotificationAuthorization()
    }

    func refreshNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        canRequestNotifications = settings.authorizationStatus == .notDetermined
        switch settings.authorizationStatus {
        case .notDetermined: notificationAuthorization = "尚未申请"
        case .denied: notificationAuthorization = "未允许"
        case .authorized: notificationAuthorization = "已允许"
        case .provisional: notificationAuthorization = "临时允许（静默）"
        case .ephemeral: notificationAuthorization = "临时允许"
        @unknown default: notificationAuthorization = "未知"
        }
        notificationAlerts = settings.alertSetting == .enabled ? "已开启" : "未开启"
        notificationLockScreen = settings.lockScreenSetting == .enabled ? "已开启" : "未开启"
        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            if permissionNotice?.hasPrefix("通知权限未开启") == true || permissionNotice?.hasPrefix("暂时无法申请通知权限") == true {
                permissionNotice = nil
            }
        }
    }

    func beginReply(attributes: ReplyActivityAttributes) {
        stopActivityTest()
        let session = LiveReplySession(attributes)
        sessions[attributes.replyID] = session
        runtime.begin(replyID: attributes.replyID, modelName: attributes.modelName)
        lastReplyStatus = "正在生成"
        activityError = nil
        if activitiesEnabled { startActivity(session) }
        else { recordActivity("实时活动开关已关闭，未创建活动") }
    }

    func retryActivity(retryDismissed: Bool = false) {
        refreshActivityAuthorization()
        guard activitiesEnabled else { return }
        for session in sessions.values where session.activity == nil {
            guard !session.dismissed || retryDismissed else { continue }
            session.dismissed = false
            startActivity(session)
        }
    }

    private func startActivity(_ session: LiveReplySession) {
        refreshActivityAuthorization()
        guard activitiesAuthorized else {
            activityError = "请在 iOS 设置 → Faculae 中开启实时活动。"
            recordActivity("系统未允许实时活动")
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            recordActivity("等待 App 回到前台创建活动")
            return
        }
        guard let plugIns = Bundle.main.builtInPlugInsURL,
              Bundle(url: plugIns.appendingPathComponent("SeekActivity.appex")) != nil else {
            activityError = "安装包缺少 SeekActivity.appex，请重新安装保留并签名扩展的 IPA。"
            recordActivity("未找到实时活动扩展")
            return
        }
        do {
            let started = try Activity.request(attributes: session.attributes,
                content: ActivityContent(state: session.state, staleDate: Date().addingTimeInterval(120), relevanceScore: 100), pushType: nil)
            session.activity = started
            activityError = nil
            recordActivity("系统已接受活动请求 · " + session.attributes.modelName)
            session.monitor = Task { [weak self, weak session] in
                for await phase in started.activityStateUpdates {
                    guard let self, let session, session.activity?.id == started.id else { return }
                    switch phase {
                    case .active: self.recordActivity("活动状态：active · " + session.attributes.modelName)
                    case .stale: self.recordActivity("活动状态：stale，等待更新")
                    case .dismissed:
                        session.dismissed = true
                        session.activity = nil
                        self.recordActivity("活动已被移除")
                        return
                    case .ended:
                        session.activity = nil
                        self.recordActivity("系统已结束活动")
                        return
                    default: self.recordActivity("活动等待系统展示")
                    }
                }
            }
        } catch {
            let detail = error as NSError
            activityError = "\(error.localizedDescription)（\(detail.domain) / \(detail.code)）"
            recordActivity("活动创建失败：" + (activityError ?? ""))
        }
    }

    func enterBackground() {
        isInBackground = true
        guard isGenerating?() == true else { return }
        for session in sessions.values { session.wasBackgrounded = true }
        onCheckpoint?()
        guard backgroundEnabled else {
            onExpiration?("后台生成已关闭，已保留收到的内容")
            return
        }
        if backgroundTask == .invalid {
            let lease = UUID()
            shortTaskToken = lease
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Continue AI replies") { [weak self] in
                Task { @MainActor in
                    guard let self, self.shortTaskToken == lease else { return }
                    self.onCheckpoint?()
                    self.endBackgroundTime()
                    self.stopUnprotectedReplies(reason: "iOS 短期后台时间已结束，已保留收到的内容")
                }
            }
        }
        if backgroundTask == .invalid { stopUnprotectedReplies(reason: "iOS 未分配后台时间，已保留收到的内容") }
        scheduleRecovery()
    }

    func enterForeground() {
        isInBackground = false
        endBackgroundTime(); retryActivity()
        runtime.enterForeground()
        Task { await refreshNotificationAuthorization() }
    }

    func updateActivity(replyID: UUID, status: String, tokens: Int, estimated: Bool, receivedBytes: Int = 0, force: Bool = false) {
        runtime.update(replyID: replyID, receivedBytes: receivedBytes, status: status, force: force)
        guard let session = sessions[replyID] else { return }
        session.state = .init(status: status, tokens: tokens, estimated: estimated)
        guard let activity = session.activity,
              force || Date().timeIntervalSince(session.lastUpdate) >= 1 else { return }
        session.lastUpdate = Date()
        let state = session.state
        let previous = session.update
        session.update = Task {
            await previous?.value
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(120), relevanceScore: 100))
        }
    }

    func endReply(modelName: String, status: String, tokens: Int, estimated: Bool, replyID: UUID, conversationID: UUID) {
        let finishedAt = Date()
        let session = sessions.removeValue(forKey: replyID)
        runtime.finish(replyID: replyID, success: status == "回复已完成")
        lastReplyStatus = status
        let wasBackgrounded = session?.wasBackgrounded == true
        if let session {
            session.state.tokens = tokens; session.state.estimated = estimated
            endActivity(session, status: status)
        }
        if isGenerating?() != true && !(recoveryEnabled && wasBackgrounded && (status.hasPrefix("iOS") || status == "回复已中断")) {
            cancelScheduledWork()
        }
        let grantedTime = isGenerating?() == true ? .invalid : backgroundTask
        if grantedTime != .invalid { backgroundTask = .invalid }
        if grantedTime != .invalid { shortTaskToken = nil }
        let shouldNotify = notificationsEnabled && wasBackgrounded
        let content = UNMutableNotificationContent()
        content.title = modelName + (status == "回复已完成" ? " 回复已完成" : " 回复已中断")
        content.body = status + " · " + (estimated ? "≈" : "") + tokens.formatted() + " tokens"
        if let startedAt = session?.attributes.startedAt {
            let seconds = max(0, Int(finishedAt.timeIntervalSince(startedAt)))
            content.body += String(format: " · %02d:%02d", seconds / 60, seconds % 60)
        }
        content.sound = .default
        content.userInfo = ["conversationID": conversationID.uuidString]
        let request = UNNotificationRequest(identifier: replyID.uuidString, content: content, trigger: nil)
        let pending = session?.update
        Task {
            await pending?.value
            if shouldNotify { try? await UNUserNotificationCenter.current().add(request) }
            if grantedTime != .invalid { UIApplication.shared.endBackgroundTask(grantedTime) }
        }
    }

    func reconcileInterruptedActivities() async {
        let liveIDs = Set(sessions.values.compactMap { $0.activity?.id })
        for item in Activity<ReplyActivityAttributes>.activities where !liveIDs.contains(item.id) {
            var state = item.content.state
            state.status = "回复已中断，请返回 App 继续"; state.endedAt = Date()
            await item.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60)))
        }
    }

    private func endActivity(_ session: LiveReplySession, status: String) {
        session.monitor?.cancel(); session.monitor = nil
        guard let activity = session.activity else { return }
        session.activity = nil
        var state = session.state
        state.status = status; state.endedAt = Date()
        let previous = session.update
        session.update = Task {
            await previous?.value
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(Date().addingTimeInterval(60)))
        }
        recordActivity("已提交活动结束状态 · " + status)
    }

    func startActivityTest(modelName: String, supplierLogo: String) {
        guard !isTestingActivity else { return }
        guard isGenerating?() != true else { return }
        let id = UUID()
        let attributes = ReplyActivityAttributes(replyID: id, conversationID: UUID(), modelName: modelName,
                                                 supplierLogo: supplierLogo, startedAt: Date())
        let session = LiveReplySession(attributes)
        session.state.status = "实时活动显示测试"; session.state.tokens = 123; session.state.estimated = false
        testReplyID = id; sessions[id] = session
        if !activitiesEnabled { activitiesEnabled = true }
        else { startActivity(session) }
        testTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard !Task.isCancelled else { return }
            self?.stopActivityTest()
        }
    }

    func stopActivityTest() {
        testTask?.cancel(); testTask = nil
        guard let id = testReplyID else { return }
        testReplyID = nil
        if let session = sessions.removeValue(forKey: id) { endActivity(session, status: "显示测试已结束") }
    }

    private func recordActivity(_ text: String) {
        // Current status remains available even when diagnostic recording is off.
        activityStatus = text
        guard activityDiagnosticsEnabled else { return }
        activityLog.info("\(text, privacy: .public)")
        let entry = ISO8601DateFormatter().string(from: Date()) + " " + text
        activityEvents.append(entry)
        activityEvents = Array(activityEvents.suffix(16))
        UserDefaults.standard.set(activityEvents, forKey: "generation.activityEvents")
    }

    func deleteActivityDiagnostics() {
        activityEvents = []
        UserDefaults.standard.removeObject(forKey: "generation.activityEvents")
    }

    private func endBackgroundTime() {
        shortTaskToken = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private func configureBackgroundRuntime() {
        runtime.configure(enabled: backgroundEnabled, location: locationKeepAliveEnabled, audio: silentAudioKeepAliveEnabled)
    }

    private func stopUnprotectedReplies(reason: String) {
        let ids = runtime.ledger.unprotectedReplies(inBackground: isInBackground, backgroundEnabled: backgroundEnabled,
            sharedExecutionAvailable: backgroundTask != .invalid || !scheduledGrants.isEmpty || runtime.hasSharedExecution)
        guard !ids.isEmpty else { return }
        onCheckpoint?()
        for id in ids { onReplyExpiration?(id, reason) }
    }

    private func scheduleRecovery() {
        guard recoveryEnabled else { return }
        let refresh = BGAppRefreshTaskRequest(identifier: Self.refreshID)
        refresh.earliestBeginDate = Date().addingTimeInterval(15 * 60)
        let processing = BGProcessingTaskRequest(identifier: Self.processingID)
        processing.requiresNetworkConnectivity = true
        processing.requiresExternalPower = false
        processing.earliestBeginDate = Date().addingTimeInterval(60)
        Task {
            do {
                try await ReplyBackgroundRuntime.submit(refresh)
                try await ReplyBackgroundRuntime.submit(processing)
                if !recoveryEnabled || isGenerating?() != true { cancelScheduledWork() }
            } catch { permissionNotice = "系统暂未接受后台恢复请求，将保留当前进度。" }
        }
    }

    private func cancelScheduledWork() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.refreshID)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.processingID)
    }

    private func handleScheduled(_ task: BGTask) {
        guard recoveryEnabled else { task.setTaskCompleted(success: true); return }
        let grant = UUID()
        scheduledGrants.insert(grant)
        let work = Task { @MainActor [weak self] in
            guard let self else { task.setTaskCompleted(success: false); return }
            defer {
                self.scheduledGrants.remove(grant)
                self.stopUnprotectedReplies(reason: "后台处理机会已结束，已保留收到的内容")
            }
            // A live in-process stream may continue while the system grants time.
            // After process termination SSE cannot be resumed safely: retain partial
            // content and end stale activities instead of silently billing a new call.
            self.onCheckpoint?()
            await self.reconcileInterruptedActivities()
            while self.recoveryEnabled && self.isGenerating?() == true && !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
                self.onCheckpoint?()
            }
            task.setTaskCompleted(success: !Task.isCancelled)
        }
        task.expirationHandler = { [weak self] in
            work.cancel()
            Task { @MainActor in
                guard let self else { return }
                self.scheduledGrants.remove(grant)
                self.stopUnprotectedReplies(reason: "iOS 后台处理时间已结束，已保留收到的内容")
            }
        }
    }
}

@MainActor
final class SeekAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationPolicy.supported
    }
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        GenerationServices.shared.registerTasks()
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = response.notification.request.content.userInfo["conversationID"] as? String,
           let url = URL(string: "seekapi://conversation/" + id) {
            Task { @MainActor in UIApplication.shared.open(url) }
        }
        completionHandler()
    }
}
