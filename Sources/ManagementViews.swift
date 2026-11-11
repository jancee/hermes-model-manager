import SwiftUI

struct EndpointList: View {
    @ObservedObject var state: StudioState
    var onEdit: (Provider) -> Void
    var onKey: (Provider) -> Void
    var onDiscover: (Provider) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                HStack(spacing: 10) {
                    heading(L("Name"), .name)
                    heading(L("URL"), .address)
                    heading(L("Default model"), .defaultModel)
                }.frame(maxWidth: .infinity, alignment: .leading)
                heading(L("Protocol"), .protocolName).frame(width: 100)
                heading(L("Model count"), .modelCount).frame(width: 86)
                heading(L("Discovery"), .discover).frame(width: 76)
                heading(L("Key"), .credential).frame(width: 58)
                Text(L("Actions")).font(.system(size: 10)).foregroundStyle(.secondary).frame(width: 148)
            }.padding(.horizontal, 12).padding(.vertical, 12).background(canvas.opacity(0.65))
            Divider()
            if state.filteredProviders.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "server.rack").font(.system(size: 34)).foregroundStyle(accent)
                    Text(state.query.isEmpty ? L("Add your first LLM endpoint") : L("No matching endpoints")).font(.headline)
                    Text(L("Create an endpoint to manage its settings, models, and favorites.")).foregroundStyle(.secondary).font(.caption)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.filteredProviders) { provider in
                            endpointRow(provider)
                            Divider().padding(.horizontal, 12)
                        }
                    }
                }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
            .padding(.horizontal, 30).padding(.bottom, 20)
    }

    private func heading(_ title: String, _ column: EndpointSortColumn) -> some View {
        SortHeader(title: title, column: column, sort: state.endpointSort) { state.sortEndpoints(column) }
    }

    private func endpointRow(_ provider: Provider) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(provider.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(provider.name)
                Text(provider.baseURL).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).textSelection(.enabled).help(provider.baseURL)
                Text(L("Default: {0}", provider.defaultModel.isEmpty ? L("Not set") : provider.defaultModel))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).help(provider.defaultModel)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Text(provider.apiMode.isEmpty ? L("Auto protocol") : modeLabel(provider.apiMode)).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(width: 100)
            Text("\(provider.configuredCount)").font(.system(size: 12, design: .monospaced)).frame(width: 86)
            Text(provider.discover ? L("Automatic") : L("Manual")).font(.system(size: 11)).foregroundStyle(accent).frame(width: 76)
            Text(provider.hasKey ? L("Configured") : L("Not configured")).font(.system(size: 10)).foregroundStyle(provider.hasKey ? Color.secondary : .orange).frame(width: 58)
            HStack(spacing: 6) {
                Button(L("Models")) { state.selection = provider.id; state.query = "" }.fixedSize().help(L("Manage this endpoint's models"))
                Button(L("Edit")) { onEdit(provider) }.fixedSize().help(L("Edit endpoint"))
                Menu {
                    Button(L("Set API key…")) { onKey(provider) }
                    Button(L("Fetch endpoint models…")) { onDiscover(provider) }
                    Divider()
                    Button(L("Delete endpoint…"), role: .destructive) { state.confirmDeleteProvider(provider) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 22)
            }.controlSize(.small).frame(width: 148).disabled(state.busy)
        }.padding(.horizontal, 12).padding(.vertical, 16)
    }
}

struct BatchEdit: Identifiable {
    let id = UUID()
    let provider: Provider
    var operation = "add"
    var models: [String] = []
}

struct BatchModelEditor: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    let edit: BatchEdit
    @State private var text = ""
    @State private var defaultModel = ""
    @State private var revision = ""
    private var ids: [String] {
        Array(Set(text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })).sorted()
    }

    init(state: StudioState, edit: BatchEdit) {
        self.state = state; self.edit = edit
        self._text = State(initialValue: edit.models.joined(separator: "\n"))
        self._defaultModel = State(initialValue: edit.models.contains(edit.provider.defaultModel) ? edit.provider.defaultModel : edit.models.sorted().first ?? "")
        self._revision = State(initialValue: state.snapshot.revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            EditorHeader(title: edit.operation == "pin" ? L("Keep only these models") : L("Add models in bulk"), subtitle: edit.provider.name)
            if edit.operation == "pin" {
                Label(L("Saving disables automatic discovery and replaces this endpoint's manual list with the models below."), systemImage: "list.bullet.rectangle")
                    .font(.system(size: 12)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            } else {
                Text(L("Enter one model ID per line. Duplicates are merged and existing model settings are preserved."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            TextEditor(text: $text).font(.system(size: 12, design: .monospaced)).frame(height: 220)
                .padding(8).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
            HStack {
                Text(L("Total: {0} models", ids.count)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if edit.operation == "pin" {
                    Picker(L("Endpoint default model"), selection: $defaultModel) {
                        ForEach(ids, id: \.self) { Text($0).tag($0) }
                    }.frame(maxWidth: 360)
                }
            }
            InlineError(error: state.error)
            HStack {
                Text(L("Validate the full batch, then save once")).font(.system(size: 10)).foregroundStyle(.secondary)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.busy)
                Button(edit.operation == "pin" ? L("Keep listed models") : L("Add models")) {
                    Task {
                        if await state.perform(["action": "batch_models", "operation": edit.operation, "provider": edit.provider.id,
                                                "models": ids, "defaultModel": defaultModel, "revision": revision]) {
                            state.selectedIDs.removeAll(); dismiss()
                        }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(state.busy || ids.isEmpty || ids.count > 1000 || (edit.operation == "pin" && !ids.contains(defaultModel)))
            }
        }.padding(28).frame(width: 610).tint(accent).interactiveDismissDisabled(state.busy)
    }
}

struct PresetEditor: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    let model: ModelRow
    @State private var effort = ""
    @State private var tier = ""

    init(state: StudioState, model: ModelRow) {
        self.state = state; self.model = model
        self._effort = State(initialValue: model.presetEffort)
        self._tier = State(initialValue: model.presetTier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeader(title: L("Client reasoning preset"), subtitle: model.providerName + " / " + model.modelID)
            Picker(L("Reasoning effort"), selection: $effort) {
                Text(L("Inherit Hermes default")).tag("")
                ForEach(["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"], id: \.self) { Text($0).tag($0) }
            }
            Picker(L("Service tier"), selection: $tier) {
                Text(L("Inherit Hermes default")).tag("")
                Text(L("Standard · normal")).tag("normal")
                Text(L("Priority · priority")).tag("priority")
                Text(L("Flex · flex")).tag("flex")
            }
            Text(L("Save to the existing Hermes client preset, applied the next time this model is selected. Supported effort levels, service tiers, and costs depend on the endpoint."))
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            InlineError(error: state.error)
            HStack {
                Button(L("Reset to inherited")) { effort = ""; tier = "" }.disabled(state.busy)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.busy)
                Button(L("Save preset")) {
                    Task {
                        if await state.perform(["action": "save_preset", "slug": model.slug, "model": model.modelID, "effort": effort, "tier": tier]) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(state.busy)
            }
        }.padding(28).frame(width: 530).tint(accent).interactiveDismissDisabled(state.busy)
    }
}
