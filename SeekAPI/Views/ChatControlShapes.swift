import SwiftUI

/// Keep the glyph above a bounded press light; release fades in 0.12 seconds.
struct QuietGlassPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay {
                Circle().fill(.white.opacity(configuration.isPressed ? 0.14 : 0))
                    .padding(1)
            }
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct HistoryGlyph: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().frame(width: 20, height: 2)
            Capsule().frame(width: 11, height: 2)
        }
    }
}

struct NewConversationGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scale = min(rect.width, rect.height) / 24
        path.move(to: CGPoint(x: 4.3, y: 17.5))
        path.addCurve(to: CGPoint(x: 12, y: 2), control1: CGPoint(x: -1, y: 11), control2: CGPoint(x: 3, y: 2))
        path.addCurve(to: CGPoint(x: 22, y: 12), control1: CGPoint(x: 17.5, y: 2), control2: CGPoint(x: 22, y: 6.5))
        path.addCurve(to: CGPoint(x: 10, y: 21.8), control1: CGPoint(x: 22, y: 18.5), control2: CGPoint(x: 16, y: 23))
        path.addLine(to: CGPoint(x: 3.4, y: 23))
        path.move(to: CGPoint(x: 12, y: 7.5))
        path.addLine(to: CGPoint(x: 12, y: 16.5))
        path.move(to: CGPoint(x: 7.5, y: 12))
        path.addLine(to: CGPoint(x: 16.5, y: 12))
        return path.strokedPath(StrokeStyle(lineWidth: 1.9, lineCap: .round, lineJoin: .round))
            .applying(CGAffineTransform(scaleX: scale, y: scale))
    }
}

extension View {
    @ViewBuilder
    func seekNativeGlassButton() -> some View {
        if #available(iOS 26, *) {
            self.buttonStyle(.glass).buttonBorderShape(.capsule)
        } else {
            self.buttonStyle(.bordered).tint(.primary).buttonBorderShape(.capsule)
        }
    }
}
