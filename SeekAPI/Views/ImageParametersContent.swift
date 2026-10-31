import SwiftUI
import SeekCore

@MainActor
struct ImageParametersContent: View {
    @Binding var settings: ImageGenerationSettings
    let provider: APIProvider
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("生图参数").font(.headline).accessibilityAddTraits(.isHeader)
            group("尺寸", icon: "aspectratio") {
                Picker("基础分辨率", selection: $settings.resolution) {
                    ForEach(ImageGenerationSettings.Resolution.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Text("图像比例")
                    Spacer()
                    Menu {
                        ForEach(ImageGenerationSettings.ratios, id: \.self) { ratio in
                            Button { settings.aspectRatio = ratio } label: {
                                Label { Text(ratio) } icon: {
                                    Image(uiImage: ratioIcon(ratio)).renderingMode(.original)
                                }
                            }
                        }
                        Divider()
                        Button { settings.aspectRatio = "custom" } label: {
                            Label { Text("自定义比例") } icon: {
                                MenuArtwork.monochromeSymbol("rectangle.and.pencil.and.ellipsis", colorScheme: colorScheme)
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Text(settings.aspectRatio == "custom" ? "自定义比例" : settings.aspectRatio)
                            Image(systemName: "chevron.up.chevron.down").font(.caption2)
                        }.foregroundStyle(.primary)
                    }
                }
                if settings.aspectRatio == "custom" {
                    HStack {
                        Text("宽 : 高")
                        TextField("例如 16:9", text: $settings.customRatio)
                            .multilineTextAlignment(.trailing).keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("自定义图像比例")
                    }
                }
                if provider == .openAI, let size = try? settings.openAISize() {
                    Text(size.replacingOccurrences(of: "x", with: " × ") + " px")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            group("质量", icon: "sparkles") {
                Picker("质量", selection: $settings.quality) {
                    ForEach(ImageGenerationSettings.Quality.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
            }
            group("格式", icon: "doc.richtext") {
                Picker("格式", selection: $settings.format) {
                    ForEach(ImageGenerationSettings.Format.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                }.pickerStyle(.segmented)
            }
            group("审核", icon: "checkmark.shield") {
                Picker("审核", selection: $settings.moderation) {
                    ForEach(ImageGenerationSettings.Moderation.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }.pickerStyle(.segmented)
            }
            if settings.format == .png {
                group("透明背景", icon: "square.dashed") {
                    Picker("透明背景", selection: $settings.transparentBackground) {
                        Text("True").tag(true)
                        Text("False").tag(false)
                    }.pickerStyle(.segmented)
                }
            } else {
                group("压缩率", icon: "arrow.down.right.and.arrow.up.left") {
                    HStack {
                        TextField("留空：不额外压缩", value: $settings.compression, format: .number.grouping(.never))
                            .keyboardType(.numberPad).accessibilityLabel("压缩率，0 至 100，可留空")
                        Text("%")
                        if settings.compression != nil {
                            Button { settings.compression = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .accessibilityLabel("清空压缩率")
                        }
                    }
                    Text("0% 不额外压缩 · 100% 最大压缩").font(.caption).foregroundStyle(.secondary)
                }
            }
            if provider == .gemini {
                Text("Gemini 的分辨率、比例和审核通过原生参数设置；质量与透明背景通过提示词请求，效果由模型决定。格式和压缩率在本机处理。")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.subheadline)
        .foregroundStyle(.primary)
        .padding(20)
        .accessibilityIdentifier("chat.imageParameters.content")
    }

    private func group<Content: View>(_ title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func ratioIcon(_ ratio: String) -> UIImage {
        let parts = ratio.split(separator: ":").compactMap { Double($0) }
        let r = parts[0] / parts[1]
        let size = CGSize(width: r >= 1 ? 22 : 22 * r, height: r >= 1 ? 22 / r : 22)
        return UIGraphicsImageRenderer(size: CGSize(width: 26, height: 26)).image { _ in
            MenuArtwork.monochromeColor(for: colorScheme).setStroke()
            let rect = CGRect(x: (26-size.width)/2, y: (26-size.height)/2, width: size.width, height: size.height)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: 2); path.lineWidth = 1.6; path.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}
