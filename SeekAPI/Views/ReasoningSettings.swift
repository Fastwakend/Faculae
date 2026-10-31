import SwiftUI
import SeekCore

@MainActor
struct ReasoningSettings: View {
    let store: AppStore
    private var profile: APIProfile { store.selectedProfile }
    private var levels: [ReasoningLevel] { profile.availableReasoningLevels }
    private var level: ReasoningLevel { profile.sliderReasoningLevel }

    private struct SliderIdentity: Hashable {
        let profileID: UUID
        let modelID: UUID
        let levels: [ReasoningLevel]
    }

    private var sliderIdentity: SliderIdentity {
        SliderIdentity(profileID: profile.id, modelID: profile.selectedModelID, levels: levels)
    }

    private var selection: Binding<Double> {
        let identity = sliderIdentity
        let stops = identity.levels
        return Binding(get: { Double(stops.firstIndex(of: level) ?? 0) }, set: { value in
            // Ignore events from a retiring control after a model switch.
            guard sliderIdentity == identity else { return }
            let index = Swift.min(Swift.max(Int(value.rounded()), 0), stops.count - 1)
            store.setReasoningLevel(stops[index])
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("推理等级", systemImage: "brain").font(.headline)
                Spacer()
                // Keep the header's layout identical for Low, Medium, Xhigh, etc.
                ZStack(alignment: .trailing) {
                    ForEach(levels) { item in
                        Text(item.title).hidden().accessibilityHidden(true)
                    }
                    Text(level.title)
                }
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: true)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(level.title)
            }
            Text(profile.modelFamily.title).font(.subheadline).foregroundStyle(.secondary)
            nativeSlider
                // The popup stays mounted for its reversible animation. Reset only
                // the native slider when its model/range changes to discard old ticks.
                // Exclude the selected level so dragging never recreates the control.
                .id(sliderIdentity)
                .controlSize(.large)
                .tint(SeekTheme.blue)
                .accessibilityLabel("推理等级")
                .accessibilityValue(level.title)
                .accessibilityIdentifier("chat.reasoning.slider")
            HStack(spacing: 0) {
                ForEach(levels) { item in
                    Button { store.setReasoningLevel(item) } label: {
                        Text(item.title)
                            .font(.caption2.weight(item == level ? .semibold : .regular))
                            .foregroundStyle(item == level ? Color(uiColor: .label) : Color.secondary)
                            .lineLimit(1).minimumScaleFactor(0.75)
                            .frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .accessibilityAddTraits(item == level ? .isSelected : [])
                }
            }
            .buttonStyle(.plain)
        }
        .padding(22)
        .foregroundStyle(Color(uiColor: .label))
        .disabled(store.isStreaming)
    }

    @ViewBuilder
    private var nativeSlider: some View {
        if #available(iOS 26, *) {
            // Apple's stepped Slider supplies native ticks and the Liquid Glass thumb.
            Slider(value: selection, in: 0...Double(levels.count - 1), step: 1,
                   label: { Text("推理等级") },
                   tick: { value in SliderTick(value) })
        } else {
            Slider(value: selection, in: 0...Double(levels.count - 1), step: 1)
        }
    }

}
