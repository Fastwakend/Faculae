import AVFoundation
import CoreLocation
import Observation
import UIKit

/// Explicit opt-in services, shared by all real replies. No coordinates are
/// retained, logged or sent over the network. Display tests never start them.
@MainActor
@Observable
final class ExperimentalBackgroundServices: NSObject, CLLocationManagerDelegate, AVAudioPlayerDelegate {
    private(set) var locationAuthorization = "尚未申请"
    private(set) var locationStatus = "等待生成任务"
    private(set) var audioStatus = "等待生成任务"
    private(set) var locationRunning = false
    private(set) var audioRunning = false
    var canRequestLocation: Bool { manager.authorizationStatus == .notDetermined }
    var canRequestAlwaysLocation: Bool { manager.authorizationStatus == .authorizedWhenInUse }
    var hasExecutionService: Bool { locationRunning || audioRunning }

    @ObservationIgnored var onExecutionChanged: (() -> Void)?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var locationSession: CLBackgroundActivitySession?
    @ObservationIgnored private var locationDiagnostics: Task<Void, Never>?
    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var audioObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var wantsLocation = false
    @ObservationIgnored private var wantsAudio = false
    @ObservationIgnored private var locationFailed = false
    @ObservationIgnored private var audioInterrupted = false
    @ObservationIgnored private var audioSessionActive = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.activityType = .other
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        refreshAuthorization()
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main) { [weak self] note in
                let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
                Task { @MainActor in self?.handleInterruption(type: type, options: options) }
            })
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.player = nil; self.audioSessionActive = false; self.audioRunning = false
                    self.audioInterrupted = false
                    self.reconcileAudio()
                    self.onExecutionChanged?()
                }
            })
        audioObservers.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereLostNotification,
            object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.player = nil; self.audioSessionActive = false; self.audioRunning = false
                    self.audioInterrupted = true; self.audioStatus = "系统音频服务暂不可用"
                    self.onExecutionChanged?()
                }
            })
    }

    func requestLocationPermission(always: Bool = false) {
        guard UIApplication.shared.applicationState == .active else { return }
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        else if always && canRequestAlwaysLocation { manager.requestAlwaysAuthorization() }
        refreshAuthorization()
    }

    func refreshAuthorization() {
        switch manager.authorizationStatus {
        case .notDetermined: locationAuthorization = "尚未申请"
        case .denied: locationAuthorization = "未允许"
        case .restricted: locationAuthorization = "系统限制"
        case .authorizedWhenInUse: locationAuthorization = "使用期间允许"
        case .authorizedAlways: locationAuthorization = "始终允许"
        @unknown default: locationAuthorization = "未知状态"
        }
    }

    func setDemand(location: Bool, audio: Bool) {
        if location != wantsLocation { locationFailed = false }
        if audio != wantsAudio { audioInterrupted = false }
        wantsLocation = location; wantsAudio = audio
        reconcileLocation(); reconcileAudio()
    }

    func enterForeground() {
        refreshAuthorization()
        locationFailed = false; audioInterrupted = false
        reconcileLocation(); reconcileAudio()
    }

    private func reconcileLocation() {
        refreshAuthorization()
        guard wantsLocation else { stopLocation(); locationStatus = "等待生成任务"; return }
        guard !locationFailed else { return }
        let authorized = manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse
        guard authorized else {
            stopLocation()
            locationStatus = canRequestLocation ? "等待定位授权" : "定位权限未允许，请打开系统设置"
            return
        }
        guard locationSession == nil else { return }
        // A new activity session must be created in direct foreground use.
        guard UIApplication.shared.applicationState == .active else {
            locationStatus = "请返回前台启动本次定位服务"; return
        }
        manager.allowsBackgroundLocationUpdates = true
        let session = CLBackgroundActivitySession()
        locationSession = session
        manager.startUpdatingLocation()
        locationRunning = true
        locationStatus = "定位服务已启动 · 仅生成期间运行"
        if #available(iOS 18, *) {
            locationDiagnostics = Task { [weak self] in
                do {
                    for try await diagnostic in session.diagnostics {
                        guard let self, !Task.isCancelled, self.locationSession === session else { return }
                        let suspended = diagnostic.authorizationDenied || diagnostic.authorizationDeniedGlobally ||
                            diagnostic.authorizationRestricted || diagnostic.insufficientlyInUse ||
                            diagnostic.serviceSessionRequired || diagnostic.authorizationRequestInProgress
                        self.locationRunning = !suspended
                        self.locationStatus = suspended ? "系统暂未允许本次后台定位" : "定位服务正在运行 · 仅生成期间"
                        self.onExecutionChanged?()
                    }
                } catch {
                    guard let self, !Task.isCancelled, self.locationSession === session else { return }
                    self.locationFailed = true
                    self.stopLocation(); self.locationStatus = "定位会话已中断，请返回前台重试"
                    self.onExecutionChanged?()
                }
            }
        }
    }

    private func stopLocation() {
        locationDiagnostics?.cancel(); locationDiagnostics = nil
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        locationSession?.invalidate(); locationSession = nil
        locationRunning = false
    }

    private func reconcileAudio() {
        guard wantsAudio else { stopAudio(); audioStatus = "等待生成任务"; return }
        guard !audioInterrupted else { audioStatus = "音频被系统中断，等待恢复"; return }
        guard player?.isPlaying != true else { audioRunning = true; return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            audioSessionActive = true
            let next = try AVAudioPlayer(data: Self.silentWAV(), fileTypeHint: AVFileType.wav.rawValue)
            next.delegate = self
            next.numberOfLoops = -1
            next.volume = 1 // The PCM samples themselves are zero.
            guard next.prepareToPlay(), next.play() else {
                throw NSError(domain: "SeekAudio", code: 1, userInfo: [NSLocalizedDescriptionKey: "系统未能启动音频播放"])
            }
            player = next; audioRunning = true
            audioStatus = "静音音频正在循环播放 · 仅生成期间"
        } catch {
            stopAudio()
            audioStatus = "音频启动失败：" + error.localizedDescription
        }
    }

    private func stopAudio() {
        player?.stop(); player = nil; audioRunning = false
        if audioSessionActive {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            audioSessionActive = false
        }
    }

    private func handleInterruption(type: UInt?, options: UInt) {
        if type == AVAudioSession.InterruptionType.began.rawValue {
            audioInterrupted = true; player?.pause(); audioRunning = false
            audioStatus = "音频被系统中断，等待恢复"
        } else if type == AVAudioSession.InterruptionType.ended.rawValue {
            audioInterrupted = !AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
            reconcileAudio()
        }
        onExecutionChanged?()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.locationFailed = false; self.reconcileLocation(); self.onExecutionChanged?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Deliberately discard the coordinates; only the service lifecycle is used.
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let temporary = (error as? CLError)?.code == .locationUnknown
        let description = error.localizedDescription
        Task { @MainActor [weak self] in
            guard let self, self.wantsLocation else { return }
            if temporary { self.locationStatus = "定位信号暂不可用，继续等待" }
            else {
                self.locationFailed = true; self.stopLocation()
                self.locationStatus = "定位已中断：" + description
                self.onExecutionChanged?()
            }
        }
    }

    nonisolated func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.stopAudio(); self.audioInterrupted = true
            self.audioStatus = "静音音频播放已中断，请返回前台重试"
            self.onExecutionChanged?()
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // An infinite loop finishing unexpectedly is no longer an execution lease.
        let identity = ObjectIdentifier(player)
        Task { @MainActor [weak self] in
            guard let self, self.wantsAudio, self.player.map(ObjectIdentifier.init) == identity else { return }
            self.stopAudio(); self.audioInterrupted = true
            self.audioStatus = "静音音频已停止，请返回前台重试"
            self.onExecutionChanged?()
        }
    }

    private static func silentWAV() -> Data {
        let samples: UInt32 = 8_000, dataSize = samples * 2
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: "RIFF".utf8); append(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8); append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
        append(samples); append(samples * 2); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: "data".utf8); append(dataSize)
        data.append(Data(repeating: 0, count: Int(dataSize)))
        return data
    }
}
