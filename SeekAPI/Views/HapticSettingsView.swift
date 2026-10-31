import SwiftUI
import SeekCore

@MainActor
struct HapticSettingsView: View {
    private let haptics = Haptics.shared
    var body: some View {
        SettingsScaffold(title: "触觉反馈") {
            Form {
                Section {
                    SeekSwitch("全局触觉反馈", isOn: haptics.binding(\.enabled))
                        .accessibilityIdentifier("haptics.global")
                    SeekSwitch("开关触觉反馈", isOn: haptics.binding(\.switches))
                    SeekSwitch("侧边栏触觉反馈", isOn: haptics.binding(\.sidebar))
                    SeekSwitch("列表项触觉反馈", isOn: haptics.binding(\.listItems))
                    SeekSwitch("卡片触觉反馈", isOn: haptics.binding(\.cards))
                    SeekSwitch("消息生成触觉反馈", isOn: haptics.binding(\.generation))
                } footer: {
                    Text("全局开关控制所有应用触觉反馈。卡片反馈用于展开和关闭思考过程；消息生成反馈仅在前台播放，并限制频率。设备与系统设置可能影响实际振动。")
                }
                Section {
                    HStack {
                        Text("触觉反馈强度调节")
                        Spacer()
                        Text(haptics.preferences.effectiveIntensity, format: .percent.precision(.fractionLength(0)))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: Binding(get: { haptics.preferences.effectiveIntensity }, set: { haptics.setIntensity($0) }),
                           in: 0...1, onEditingChanged: { editing in if !editing { haptics.play() } })
                        .tint(SeekTheme.blue)
                        .accessibilityLabel("触觉反馈强度调节")
                        .accessibilityIdentifier("haptics.intensity")
                    HStack { Text("弱"); Spacer(); Text("强") }.font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}
