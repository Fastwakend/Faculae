import ActivityKit
import SwiftUI
import WidgetKit
import UIKit

@main
struct SeekActivityBundle: WidgetBundle {
    var body: some Widget { SeekReplyWidget() }
}

struct SeekReplyWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ReplyActivityAttributes.self) { context in
            HStack(spacing: 12) {
                SupplierActivityLogo(name: context.attributes.supplierLogo, size: 30)
                VStack(alignment: .leading, spacing: 5) {
                    Text(context.attributes.modelName + (context.state.endedAt == nil ? " 正在生成" : " 回复已结束"))
                        .font(.headline).lineLimit(1)
                    Text(context.isStale && context.state.endedAt == nil ? "连接状态待确认，请返回 App" : context.state.status).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 5) {
                    ReplyTimer(start: context.attributes.startedAt, end: context.state.endedAt)
                    TokenCounter(state: context.state)
                }
                .font(.subheadline).monospacedDigit()
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(.black.opacity(0.85))
            .activitySystemActionForegroundColor(.white)
            .environment(\.colorScheme, .dark)
            .widgetURL(URL(string: "seekapi://conversation/" + context.attributes.conversationID.uuidString))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading, priority: 1) {
                    ExpandedModelIdentity(attributes: context.attributes, state: context.state, isStale: context.isStale)
                        .dynamicIsland(verticalPlacement: .belowIfTooWide)
                }
                DynamicIslandExpandedRegion(.trailing, priority: 2) {
                    ExpandedReplyMetrics(startedAt: context.attributes.startedAt, state: context.state)
                }
            } compactLeading: {
                SupplierActivityLogo(name: context.attributes.supplierLogo, size: 20)
            } compactTrailing: {
                ReplyTimer(start: context.attributes.startedAt, end: context.state.endedAt)
                    .font(.caption2).monospacedDigit().frame(width: 46)
            } minimal: {
                SupplierActivityLogo(name: context.attributes.supplierLogo, size: 18)
            }
            // Use the upper side regions beside the camera rather than reserving
            // an empty upper row above a bottom-only card. Keep curved-edge insets.
            .contentMargins(.horizontal, 28, for: .expanded)
            .contentMargins(.vertical, 14, for: .expanded)
            .keylineTint(.white.opacity(0.6))
            .widgetURL(URL(string: "seekapi://conversation/" + context.attributes.conversationID.uuidString))
        }
    }
}

private struct ExpandedModelIdentity: View {
    let attributes: ReplyActivityAttributes
    let state: ReplyActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 6) {
                SupplierActivityLogo(name: attributes.supplierLogo, size: 20)
                Text(attributes.modelName)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2).minimumScaleFactor(0.85)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(isStale && state.endedAt == nil ? "连接状态待确认，请返回 App" : state.status)
                .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.78))
                .lineLimit(2).minimumScaleFactor(0.9)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 160, alignment: .leading)
        .padding(.leading, 4)
        .padding(.top, 5)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

private struct ExpandedReplyMetrics: View {
    let startedAt: Date
    let state: ReplyActivityAttributes.ContentState

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            ReplyTimer(start: startedAt, end: state.endedAt)
                .font(.system(size: 14, weight: .semibold)).monospacedDigit()
                .frame(maxWidth: .infinity, alignment: .trailing)
            TokenCounter(state: state)
                .font(.system(size: 11.5)).monospacedDigit()
        }
        // Timer text has no stable intrinsic width: reserve its region explicitly
        // instead of asking fixedSize to negotiate space with the model name.
        .frame(width: 82, alignment: .trailing)
        .padding(.trailing, 12)
        .padding(.top, 7)
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
    }
}

private struct SupplierActivityLogo: View {
    let name: String
    let size: CGFloat
    var body: some View {
        Group {
            if let image = UIImage(named: "Model" + name, in: .main, compatibleWith: nil) {
                Image(uiImage: image)
                    .renderingMode(name == "OpenAI" || name == "Claude" ? .template : .original)
                    .resizable().scaledToFit()
                    .foregroundStyle(name == "Claude" ? Color(red: 0.80, green: 0.47, blue: 0.35) : .white)
            } else {
                Text(String(name.prefix(1))).font(.system(size: size * 0.8, weight: .bold)).foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(name)
    }
}

private struct ReplyTimer: View {
    let start: Date
    let end: Date?
    var body: some View {
        if let end {
            let seconds = max(0, Int(end.timeIntervalSince(start)))
            Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
                .foregroundStyle(.white)
        } else {
            Text(timerInterval: start...start.addingTimeInterval(8 * 60 * 60), countsDown: false)
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.white)
        }
    }
}

private struct TokenCounter: View {
    let state: ReplyActivityAttributes.ContentState
    var body: some View {
        Text((state.estimated ? "≈" : "") + state.tokens.formatted() + " tokens")
            .lineLimit(1).minimumScaleFactor(0.75).foregroundStyle(.white.opacity(0.82))
    }
}
