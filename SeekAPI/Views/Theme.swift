import SwiftUI
import SeekCore

enum SeekTheme {
    static let composerOutline = Color(white: 0.52)
    static let blue = Color(red: 0.30, green: 0.42, blue: 0.96)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.25)
}

@MainActor
enum MenuArtwork {
    static func monochromeColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark ? .white : .black
    }

    /// Resolve the app's current appearance before handing the image to UIKit.
    /// Original pixels prevent menu tint or a destructive role recoloring it.
    static func monochromeSymbol(_ name: String, colorScheme: ColorScheme) -> Image {
        let image = UIImage(systemName: name) ?? UIImage()
        return Image(uiImage: image.withTintColor(monochromeColor(for: colorScheme), renderingMode: .alwaysOriginal))
            .renderingMode(.original)
    }
}

/// Keep every Boolean control a system switch. iOS 26+ supplies Liquid Glass
/// during interaction; earlier systems retain their native switch appearance.
@MainActor
struct SeekSwitch: View {
    let title: LocalizedStringKey
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, isOn: Binding<Bool>) {
        self.title = title
        _isOn = isOn
    }

    var body: some View {
        Toggle(title, isOn: Binding(get: { isOn }, set: { value in
            isOn = value
            Haptics.shared.play(.switches)
        }))
            .toggleStyle(.switch)
            .tint(.green)
    }
}

@MainActor
struct SeekMark: View {
    var size: CGFloat = 46
    var body: some View {
        ModelLogo(model: "deepseek-chat", provider: .openAI, size: size)
    }
}

@MainActor
struct ModelLogo: View {
    let model: String
    var provider: APIProvider = .openAI
    var iconStyle: ModelIconStyle? = nil
    var customIconID: UUID? = nil
    var size: CGFloat = 46
    var templateTint: Color? = nil

    init(model: String, provider: APIProvider = .openAI, iconStyle: ModelIconStyle? = nil,
         customIconID: UUID? = nil, size: CGFloat = 46, templateTint: Color? = nil) {
        self.model = model
        self.provider = provider
        self.iconStyle = iconStyle
        self.customIconID = customIconID
        self.size = size
        self.templateTint = templateTint
    }

    init(model: APIModel, provider: APIProvider = .openAI, size: CGFloat = 46, templateTint: Color? = nil) {
        self.init(model: model.model, provider: provider, iconStyle: model.iconStyle,
                  customIconID: model.customIconID, size: size, templateTint: templateTint)
    }

    private var brand: String { Self.brandName(model: model, provider: provider, iconStyle: iconStyle) }

    static func brandName(model: String, provider: APIProvider, iconStyle: ModelIconStyle?) -> String {
        switch iconStyle ?? .automatic {
        case .openAI: return "OpenAI"
        case .deepSeek: return "DeepSeek"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .automatic, .custom:
            return APIProfile(name: "", provider: provider, model: model).modelFamily.title
        }
    }

    private var bitmap: UIImage? { Self.bitmaps[brand] }
    private static let bitmaps: [String: UIImage] = {
        var images: [String: UIImage] = [:]
        for brand in ["OpenAI", "Claude", "Gemini", "DeepSeek"] {
            let name = "Model" + brand
            // xtool copies root PNGs; Xcode compiles the asset catalog.
            if let url = Bundle.main.url(forResource: name, withExtension: "png"),
               let image = UIImage(contentsOfFile: url.path) { images[brand] = image }
            else { images[brand] = UIImage(named: name, in: .main, compatibleWith: nil) }
        }
        return images
    }()

    var body: some View {
        Group {
            if iconStyle == .custom, let customIconID, let image = ModelIconStore.image(for: customIconID) {
                Image(uiImage: image).renderingMode(.original).resizable().scaledToFit()
            } else if let bitmap {
                Image(uiImage: bitmap)
                    .renderingMode(brand == "OpenAI" || brand == "Claude" ? .template : .original)
                    .resizable().scaledToFit()
                    .foregroundStyle(brand == "Claude" ? Color(red: 0.80, green: 0.47, blue: 0.35) : (templateTint ?? Color(uiColor: .label)))
            } else {
                Image(systemName: "sparkles").resizable().scaledToFit().foregroundStyle(SeekTheme.blue)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(iconStyle == .custom ? "自定义模型图标" : brand)
    }
}

/// Native menus reserve their image gutter only when the row has an image.
/// Supply a real transparent bitmap for unselected rows to keep titles aligned.
@MainActor
struct MenuSelectionLabel: View {
    let title: String
    let isSelected: Bool
    private static let blankIcon = UIGraphicsImageRenderer(size: CGSize(width: 20, height: 20)).image { _ in }

    var body: some View {
        Label {
            Text(title)
        } icon: {
            if isSelected { Image(systemName: "checkmark") }
            else { Image(uiImage: Self.blankIcon).renderingMode(.template) }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

@MainActor
struct CircleIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void
    var body: some View {
        Button { Haptics.shared.play(); action() } label: {
            Image(systemName: symbol)
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
                .seekGlass(in: Circle())
        }
        .buttonStyle(QuietGlassPressStyle())
        .accessibilityLabel(label)
    }
}

extension View {
    /// Attachment sheet content lets the native presentation supply its glass.
    @ViewBuilder
    func seekSheetContentBackground() -> some View {
        if #available(iOS 26, *) {
            self
        } else {
            self.background(Color(uiColor: .systemGroupedBackground))
        }
    }

    /// System Liquid Glass on iOS 26+, with a system material on earlier releases.
    @ViewBuilder
    func seekGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        if #available(iOS 26, *) {
            self.glassEffect(.regular.interactive(interactive), in: shape)
        } else {
            self.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(SeekTheme.border, lineWidth: 0.5))
        }
    }
}

@MainActor
struct SeekGlassGroup<Content: View>: View {
    let spacing: CGFloat
    let content: Content

    init(spacing: CGFloat = 12, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        if #available(iOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String {
        switch self { case .system: "系统"; case .light: "浅色"; case .dark: "深色" }
    }
    var colorScheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

enum ChatTextSize: String, CaseIterable, Identifiable {
    case standard, large, larger
    var id: String { rawValue }
    var title: String {
        switch self { case .standard: "标准"; case .large: "较大"; case .larger: "更大" }
    }
    var scale: CGFloat {
        switch self { case .standard: 1; case .large: 1.12; case .larger: 1.25 }
    }
}

private struct ChatTextScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat = 1
}

extension EnvironmentValues {
    var chatTextScale: CGFloat {
        get { self[ChatTextScaleKey.self] }
        set { self[ChatTextScaleKey.self] = newValue }
    }
}
