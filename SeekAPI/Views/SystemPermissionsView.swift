import SwiftUI
import AVFoundation
import Photos
import UserNotifications

@MainActor
struct SystemPermissionsView: View {
    let store: AppStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    @State private var savePhotos = PHPhotoLibrary.authorizationStatus(for: .addOnly)
    @State private var background = UIApplication.shared.backgroundRefreshStatus
    @State private var requesting = false

    private enum Permission { case camera, photos, savePhotos, notifications, activities, background, location }

    var body: some View {
        let services = store.backgroundServices
        SettingsScaffold(title: "系统权限") {
            Form {
                Section {
                    permissionRow("相机", symbol: "camera", status: cameraStatus, permission: .camera)
                    permissionRow("最近照片", symbol: "photo.on.rectangle", status: photoStatus(photos), permission: .photos)
                    permissionRow("保存图片到相册", symbol: "square.and.arrow.down", status: photoStatus(savePhotos), permission: .savePhotos)
                } header: { Text("照片与相机") } footer: {
                    Text("点击未申请的权限可向系统申请；已拒绝时打开系统设置。相册选择器可直接选择指定照片，无需允许整个图库；“最近照片”权限用于显示附件面板中的照片。系统限制可能需要在屏幕使用时间中调整。")
                }

                Section {
                    permissionRow("任务通知", symbol: "bell.badge", status: services.notificationAuthorization, permission: .notifications)
                    LabeledContent("通知横幅", value: services.notificationAlerts)
                    LabeledContent("锁屏显示", value: services.notificationLockScreen)
                    permissionRow("实时活动", symbol: "rectangle.topthird.inset.filled",
                        status: services.activitiesAuthorized ? "已允许" : "未允许", permission: .activities)
                    permissionRow("更频繁的实时活动更新", symbol: "arrow.clockwise",
                        status: services.frequentUpdatesAllowed ? "已允许" : "未允许", permission: .activities)
                    permissionRow("后台 App 刷新", symbol: "arrow.triangle.2.circlepath", status: backgroundStatus, permission: .background)
                    permissionRow("定位（实验性后台生成）", symbol: "location",
                        status: services.runtime.experiments.locationAuthorization, permission: .location)
                } header: { Text("通知与后台") } footer: {
                    Text("这里显示 iOS 的授权状态。任务通知、实时活动和后台生成还需在 App 的“后台生成”页面开启。点击可前往系统设置；后台 App 刷新的总开关位于系统设置 → 通用。后台执行时长和调度由 iOS 决定。")
                }

                Section {
                    LabeledContent { Text("逐个文件授权").foregroundStyle(.secondary) } label: {
                        Label("文件访问", systemImage: "folder")
                    }
                    Text("在系统文件选择器中选择文件并点击“打开”，即可授权导入所选文件；iOS 没有全局文件访问权限开关。")
                        .font(.footnote).foregroundStyle(.secondary)
                } header: { Text("文件") }
            }
            .disabled(requesting)
        }
        .task { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
    }

    private func permissionRow(_ title: String, symbol: String, status: String, permission: Permission) -> some View {
        Button { select(permission) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24).accessibilityHidden(true)
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 12)
                Text(status).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.trailing)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("申请权限或打开系统设置")
    }

    private var cameraStatus: String {
        switch camera {
        case .notDetermined: return "未申请"
        case .authorized: return "已允许"
        case .denied: return "未允许"
        case .restricted: return "系统限制"
        @unknown default: return "未知状态"
        }
    }

    private func photoStatus(_ status: PHAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "未申请"
        case .authorized: return "已允许"
        case .limited: return "部分照片"
        case .denied: return "未允许"
        case .restricted: return "系统限制"
        @unknown default: return "未知状态"
        }
    }

    private var backgroundStatus: String {
        switch background {
        case .available: return "已允许"
        case .denied: return "未允许"
        case .restricted: return "系统限制"
        @unknown default: return "未知状态"
        }
    }

    private func refresh() async {
        camera = AVCaptureDevice.authorizationStatus(for: .video)
        photos = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        savePhotos = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        background = UIApplication.shared.backgroundRefreshStatus
        store.backgroundServices.refreshActivityAuthorization()
        store.backgroundServices.runtime.experiments.refreshAuthorization()
        await store.backgroundServices.refreshNotificationAuthorization()
    }

    private func select(_ permission: Permission) {
        guard !requesting else { return }
        requesting = true
        Task {
            defer { requesting = false }
            switch permission {
            case .camera where camera == .notDetermined:
                _ = await AVCaptureDevice.requestAccess(for: .video)
            case .photos where photos == .notDetermined:
                _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
            case .savePhotos where savePhotos == .notDetermined:
                _ = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            case .notifications where store.backgroundServices.canRequestNotifications:
                await store.backgroundServices.requestNotificationPermission()
            case .location where store.backgroundServices.runtime.experiments.canRequestLocation:
                store.backgroundServices.runtime.experiments.requestLocationPermission()
            default:
                let path = permission == .notifications ? UIApplication.openNotificationSettingsURLString : UIApplication.openSettingsURLString
                if let url = URL(string: path) { await UIApplication.shared.open(url) }
            }
            await refresh()
        }
    }
}
