import BackgroundTasks
import Observation
import SeekCore
import UIKit

@MainActor
@Observable
final class ReplyBackgroundRuntime {
    static let continuedPrefix = "app.seekapi.ios.reply.continued."
    let experiments = ExperimentalBackgroundServices()
    private(set) var continuedStatus = "等待生成任务"
    private(set) var ledger = ReplyExecutionLedger()
    var runningTaskCount: Int { ledger.running.count }
    var pendingTaskCount: Int { ledger.requests.count - ledger.running.count }
    var hasSharedExecution: Bool { experiments.hasExecutionService }

    @ObservationIgnored var onReplyExpiration: ((UUID, String) -> Void)?
    @ObservationIgnored var onExecutionChanged: (() -> Void)?
    @ObservationIgnored private var enabled = true
    @ObservationIgnored private var locationEnabled = false
    @ObservationIgnored private var audioEnabled = false
    @ObservationIgnored private var titles: [UUID: String] = [:]
    @ObservationIgnored private var bytes: [UUID: Int64] = [:]
    @ObservationIgnored private var tasks: [UUID: BGTask] = [:]
    @ObservationIgnored private var attempted: Set<UUID> = []
    @ObservationIgnored private var lastProgress: [UUID: Date] = [:]

    init() {
        experiments.onExecutionChanged = { [weak self] in self?.onExecutionChanged?() }
    }

    func configure(enabled: Bool, location: Bool, audio: Bool) {
        let wasEnabled = self.enabled
        self.enabled = enabled; locationEnabled = location; audioEnabled = audio
        if !enabled { releaseContinuedTasks() }
        if enabled && !wasEnabled {
            for id in ledger.replies { submitIfPossible(id) }
        }
        reconcileExperiments()
        onExecutionChanged?()
    }

    func begin(replyID: UUID, modelName: String) {
        guard ledger.begin(replyID) else { return }
        titles[replyID] = modelName; bytes[replyID] = 0
        if enabled { submitIfPossible(replyID) }
        reconcileExperiments()
    }

    /// Stream length is unknown. Use indeterminate progress with real received
    /// byte counts, never a timer or a guessed completion percentage.
    func update(replyID: UUID, receivedBytes: Int, status: String, force: Bool) {
        guard ledger.replies.contains(replyID) else { return }
        bytes[replyID] = max(bytes[replyID] ?? 0, Int64(max(0, receivedBytes)))
        guard force || Date().timeIntervalSince(lastProgress[replyID] ?? .distantPast) >= 1 else { return }
        lastProgress[replyID] = Date()
        if #available(iOS 26, *), let task = tasks[replyID] as? BGContinuedProcessingTask {
            task.progress.completedUnitCount = bytes[replyID] ?? 0
            let count = bytes[replyID] ?? 0
            task.updateTitle(titles[replyID] ?? "生成回复", subtitle: count > 0 ? "\(status) · 已接收 \(count.formatted()) 字节" : status)
        }
    }

    func finish(replyID: UUID, success: Bool) {
        let requestID = ledger.requests[replyID]
        ledger.finish(replyID)
        if let task = tasks.removeValue(forKey: replyID) {
            task.expirationHandler = nil
            if #available(iOS 26, *), let continued = task as? BGContinuedProcessingTask, success {
                let total = max(1, bytes[replyID] ?? 0)
                continued.progress.totalUnitCount = total
                continued.progress.completedUnitCount = total
            }
            task.setTaskCompleted(success: success)
        }
        if let requestID { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(requestID)) }
        titles[replyID] = nil; bytes[replyID] = nil; lastProgress[replyID] = nil; attempted.remove(replyID)
        if ledger.replies.isEmpty { continuedStatus = success ? "最近任务已完成" : "最近任务已结束" }
        reconcileExperiments()
    }

    func enterForeground() { experiments.enterForeground() }

    private func reconcileExperiments() {
        experiments.setDemand(location: ledger.needsExperiments(backgroundEnabled: enabled, experimentEnabled: locationEnabled),
                              audio: ledger.needsExperiments(backgroundEnabled: enabled, experimentEnabled: audioEnabled))
    }

    private static func identifier(_ requestID: UUID) -> String { continuedPrefix + requestID.uuidString }

    private func submitIfPossible(_ replyID: UUID) {
        guard #available(iOS 26, *) else { continuedStatus = "此系统使用短期后台时间（持续任务需 iOS 26 及以上）"; return }
        guard UIApplication.shared.applicationState == .active else {
            continuedStatus = "本次未在前台申请持续任务，使用其他可用后台时间"; return
        }
        guard !attempted.contains(replyID) else { return }
        let requestID = UUID()
        guard ledger.prepare(replyID, requestID: requestID) else { return }
        attempted.insert(replyID)
        let identifier = Self.identifier(requestID)
        // Apple permits continued-task registration after application launch.
        // Register the exact per-job identifier once; the plist permits this prefix.
        let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            Task { @MainActor in
                guard let self else { task.setTaskCompleted(success: false); return }
                self.accept(task, replyID: replyID, requestID: requestID)
            }
        }
        guard registered else {
            ledger.reject(replyID, requestID: requestID)
            continuedStatus = "系统未注册持续任务，请检查安装包后台声明"
            return
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier,
            title: titles[replyID] ?? "生成回复", subtitle: "正在准备回复")
        request.strategy = .fail
        continuedStatus = "正在请求系统持续后台任务"
        Task { [weak self] in
            guard let self, self.ledger.matches(replyID, requestID: requestID), self.enabled else { return }
            do {
                try await Self.submit(request)
                guard self.ledger.matches(replyID, requestID: requestID) else {
                    BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier); return
                }
                if !self.ledger.running.contains(replyID) { self.continuedStatus = "请求已提交，等待系统启动" }
            } catch {
                guard self.ledger.matches(replyID, requestID: requestID), !self.ledger.running.contains(replyID) else { return }
                self.ledger.reject(replyID, requestID: requestID)
                self.continuedStatus = "持续任务未获批准：" + error.localizedDescription
                self.onExecutionChanged?()
            }
        }
    }

    @available(iOS 26, *)
    private func accept(_ task: BGTask, replyID: UUID, requestID: UUID) {
        guard let continued = task as? BGContinuedProcessingTask,
              enabled, ledger.accept(replyID, requestID: requestID) else {
            task.setTaskCompleted(success: false); return
        }
        tasks[replyID] = continued
        continued.progress.totalUnitCount = -1
        continued.progress.completedUnitCount = bytes[replyID] ?? 0
        continued.expirationHandler = { [weak self] in
            Task { @MainActor in
                guard let self, self.ledger.expire(replyID, requestID: requestID) else { return }
                self.tasks[replyID] = nil
                continued.setTaskCompleted(success: false)
                self.continuedStatus = "持续任务已被系统或用户结束，已保存当前回复"
                // The system uses this handler for user cancellation too. Respect
                // that cancellation even if an experimental service is running.
                self.onReplyExpiration?(replyID, "iOS 持续后台任务已结束，已保留收到的内容")
            }
        }
        continuedStatus = "系统持续后台任务正在运行"
    }

    private func releaseContinuedTasks() {
        let requests = Array(ledger.requests.values)
        ledger.releaseContinuedRequests()
        for task in tasks.values { task.expirationHandler = nil; task.setTaskCompleted(success: false) }
        tasks.removeAll(); attempted.removeAll()
        for id in requests { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.identifier(id)) }
        continuedStatus = "后台生成已关闭"
    }

    /// iOS 27 reports all submission errors through its new completion API.
    static func submit(_ request: BGTaskRequest) async throws {
        if #available(iOS 27, *) { try await BGTaskScheduler.shared.submitTaskRequest(request) }
        else { try BGTaskScheduler.shared.submit(request) }
    }
}
