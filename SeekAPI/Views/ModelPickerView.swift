import SwiftUI
import SeekCore

@MainActor
struct ModelPickerView: View {
    @Binding var profile: APIProfile
    let availableIDs: [String]
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var errorText: String?

    private var filtered: [String] {
        availableIDs.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        SettingsScaffold(title: "选择模型", onSave: addModels, saveDisabled: selected.isEmpty) {
            List {
                Section {
                    TextField("搜索模型", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settings.models.search")
                    HStack {
                        Text("已选 \(selected.count) 个").foregroundStyle(.secondary)
                        Spacer()
                        Button("全选结果") {
                            selected.formUnion(filtered.filter { !profile.containsModel($0) })
                        }
                        Button("清除") { selected.removeAll() }.disabled(selected.isEmpty)
                    }
                    .font(.subheadline)
                } footer: { Text("点击右上角添加所选模型，再回到供应商页面保存。") }
                Section("可用模型（\(filtered.count)）") {
                    ForEach(filtered, id: \.self) { id in
                        let existing = profile.containsModel(id)
                        Button {
                            if !selected.insert(id).inserted { selected.remove(id) }
                            Haptics.shared.play(.listItem)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: existing || selected.contains(id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(selected.contains(id) ? SeekTheme.blue : Color.secondary)
                                Text(id).font(.subheadline).foregroundStyle(Color(uiColor: .label))
                                Spacer()
                                if existing { Text("已添加").font(.caption).foregroundStyle(.secondary) }
                            }
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(existing)
                        .accessibilityAddTraits(selected.contains(id) || existing ? .isSelected : [])
                    }
                }
                if let errorText { Section { Text(errorText).font(.caption).foregroundStyle(.red) } }
            }
        }
    }

    private func addModels() {
        do {
            var candidate = profile
            for id in availableIDs where selected.contains(id) && !candidate.containsModel(id) {
                try candidate.addModel(id)
            }
            try RequestBuilder.validateAllModels(candidate)
            profile = candidate
            dismiss()
        } catch { errorText = error.localizedDescription }
    }
}
