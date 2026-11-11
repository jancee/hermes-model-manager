import SwiftUI

struct ModelEdit: Identifiable {
    let id = UUID()
    var provider: Provider
    var row: ModelRow?
}

struct EditorHeader: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 22, weight: .bold))
            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.bottom, 10)
    }
}

struct InlineError: View {
    var error: String?
    var body: some View {
        if let error { Label(L(error), systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true) }
    }
}

struct ProviderEditor: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    @State var provider: Provider
    @State private var revision = ""
    private var create: Bool { originalID.isEmpty }
    private let originalID: String

    init(state: StudioState, provider: Provider) {
        self.state = state; self._provider = State(initialValue: provider); self.originalID = provider.id
        self._revision = State(initialValue: state.snapshot.revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            EditorHeader(title: create ? L("Add endpoint") : L("Edit endpoint"), subtitle: L("Configure the endpoint and its manual model list. A backup is created before saving. Existing sessions may need to reload."))
            Form {
                Section(L("Endpoint")) {
                    TextField(L("Endpoint ID"), text: $provider.id).disabled(!create)
                    LabeledContent(L("Display name")) {
                        EndpointNameField(text: $provider.name, language: state.language).frame(minWidth: 240, maxWidth: .infinity).frame(height: 26)
                    }
                    TextField("Base URL", text: $provider.baseURL).help(L("For example: https://api.example.com/v1"))
                    Picker(L("API protocol"), selection: $provider.apiMode) {
                        Text(L("Automatic")).tag("")
                        Text("Chat Completions").tag("chat_completions")
                        Text("Codex Responses").tag("codex_responses")
                        Text("Responses").tag("responses")
                        Text("Anthropic Messages").tag("anthropic_messages")
                        if !["", "chat_completions", "codex_responses", "responses", "anthropic_messages"].contains(provider.apiMode) {
                            Text(provider.apiMode).tag(provider.apiMode)
                        }
                    }
                }
                Section(L("Model")) {
                    TextField(L("Endpoint default model"), text: $provider.defaultModel)
                    TextField(L("Context length (blank for automatic)"), text: $provider.context)
                    Toggle(L("Discover models automatically"), isOn: $provider.discover)
                    Text(provider.discover ? L("When enabled, Hermes may list every model offered by the endpoint.") : L("When disabled, only the manual model list is used. The default model is added to that list automatically."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(L("Credentials")) {
                    TextField(L("API key variable"), text: $provider.keyEnv)
                    Text(L("Leave blank to generate a variable name. Save the endpoint, then enter the key under Endpoint settings → Set API key."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Section(L("Timeouts")) {
                    TextField(L("Request timeout (s)"), text: $provider.requestTimeout)
                    TextField(L("No-response timeout (s)"), text: $provider.staleTimeout)
                    Text(L("Leave blank to inherit Hermes defaults. Per-model timeouts take precedence."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).scrollContentBackground(.hidden).frame(height: 465)
            InlineError(error: state.error)
            HStack {
                if !create { Text(L("The ID stays fixed to preserve favorites and existing routes. ")).font(.system(size: 10)).foregroundStyle(.secondary) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.busy)
                Button(L("Save endpoint")) { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(state.busy || provider.id.trimmingCharacters(in: .whitespaces).isEmpty || provider.baseURL.isEmpty)
            }
        }.padding(26).frame(width: 610).tint(accent).interactiveDismissDisabled(state.busy)
    }

    private func save() {
        let name = provider.name.isEmpty ? provider.id : provider.name
        Task {
            let ok = await state.perform(["action": "save_provider", "create": create, "provider": provider.id,
                "name": name, "baseURL": provider.baseURL, "apiMode": provider.apiMode,
                "defaultModel": provider.defaultModel, "discover": provider.discover,
                "context": provider.context, "keyEnv": provider.keyEnv, "requestTimeout": provider.requestTimeout,
                "staleTimeout": provider.staleTimeout, "revision": revision])
            if ok { state.selection = provider.id; dismiss() }
        }
    }
}

struct ModelEditor: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    let edit: ModelEdit
    @State private var model = ""
    @State private var context = ""
    @State private var requestTimeout = ""
    @State private var staleTimeout = ""
    @State private var revision = ""

    init(state: StudioState, edit: ModelEdit) {
        self.state = state; self.edit = edit
        self._model = State(initialValue: edit.row?.modelID ?? "")
        self._context = State(initialValue: edit.row?.context ?? "")
        self._requestTimeout = State(initialValue: edit.row?.requestTimeout ?? "")
        self._staleTimeout = State(initialValue: edit.row?.staleTimeout ?? "")
        self._revision = State(initialValue: state.snapshot.revision)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeader(title: edit.row?.configured == true ? L("Edit model") : L("Add model"), subtitle: edit.provider.name)
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Model ID")).font(.system(size: 12, weight: .medium))
                TextField(L("For example: model-id"), text: $model).textFieldStyle(.roundedBorder).disabled(edit.row?.configured == true)
                Text(L("Enter a model ID supported by the endpoint. Hermes generates its own display name."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(L("Context length")).font(.system(size: 12, weight: .medium))
                TextField(L("Leave blank for Hermes automatic value"), text: $context).textFieldStyle(.roundedBorder)
                Text(L("This sets the context length managed by Hermes. It does not change the endpoint's own limit."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("Request timeout (s)")).font(.system(size: 12, weight: .medium))
                    TextField(L("Inherit endpoint setting"), text: $requestTimeout).textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Text(L("No-response timeout (s)")).font(.system(size: 12, weight: .medium))
                    TextField(L("Inherit endpoint setting"), text: $staleTimeout).textFieldStyle(.roundedBorder)
                }
            }
            InlineError(error: state.error)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(state.busy)
                Button(L("Save model")) {
                    Task {
                        if await state.perform(["action": "save_model", "provider": edit.provider.id,
                            "model": model, "originalModel": edit.row?.modelID ?? model,
                            "context": context, "requestTimeout": requestTimeout, "staleTimeout": staleTimeout,
                            "create": edit.row?.configured != true, "revision": revision]) { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(state.busy || model.isEmpty)
            }
        }.padding(28).frame(width: 500).tint(accent).interactiveDismissDisabled(state.busy)
    }
}

struct KeyEditor: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    let provider: Provider
    @State private var secret = ""
    @State private var revision = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            EditorHeader(title: L("Set API key"), subtitle: provider.name)
            Text(provider.hasKey ? L("This endpoint already has a key. Saving replaces its variable value. Cancel to keep the existing key.") : L("The key is saved only in your local Hermes .env file."))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            SecureField(L("Paste API key"), text: $secret).textFieldStyle(.roundedBorder)
            Text(provider.keyEnv).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            InlineError(error: state.error)
            HStack {
                Spacer()
                Button(L("Cancel")) { secret = ""; dismiss() }.keyboardShortcut(.cancelAction).disabled(state.busy)
                Button(L("Save key")) {
                    Task {
                        let ok = await state.perform(["action": "save_key", "provider": provider.id, "secret": secret, "revision": revision])
                        if ok { secret = ""; dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(state.busy || secret.isEmpty)
            }
        }.padding(28).frame(width: 510).tint(accent).interactiveDismissDisabled(state.busy)
            .onAppear { revision = state.snapshot.revision }
    }
}

struct DiscoveryView: View {
    @ObservedObject var state: StudioState
    @Environment(\.dismiss) private var dismiss
    let provider: Provider
    @State private var models: [String] = []
    @State private var query = ""
    @State private var selected = Set<String>()
    @State private var loading = true
    @State private var adding = false
    @State private var failure: String?
    @State private var note = "Fetching endpoint models…"
    @State private var sort = ListSort<DiscoverySortColumn>.load("studio.sort.discovery", default: .name)
    private var configured: Set<String> { Set(state.snapshot.models.filter { $0.providerID == provider.id && $0.configured }.map(\.modelID)) }
    private var visibleModels: [String] {
        RowSort.discovered(models.filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }, configured: configured, selected: selected, by: sort)
    }
    private func sortBy(_ column: DiscoverySortColumn) {
        sort.select(column)
        if !state.preview { sort.save("studio.sort.discovery") }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            EditorHeader(title: L("Add models from endpoint"), subtitle: L("Fetch the model list, then choose which models to add to your manual configuration."))
            TextField(L("Search model IDs"), text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Button(L("Select all results")) { selected.formUnion(models.filter { !configured.contains($0) && (query.isEmpty || $0.localizedCaseInsensitiveContains(query)) }) }
                Button(L("Clear selection")) { selected.removeAll() }
                Spacer()
            }.font(.caption).disabled(loading || adding)
            if loading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            else {
                HStack(spacing: 8) {
                    SortHeader(title: L("Selected"), column: .selected, sort: sort) { sortBy(.selected) }.frame(width: 60, alignment: .leading)
                    SortHeader(title: L("Model ID"), column: .name, sort: sort) { sortBy(.name) }.frame(maxWidth: .infinity, alignment: .leading)
                    SortHeader(title: L("Status"), column: .configured, sort: sort) { sortBy(.configured) }.frame(width: 88, alignment: .trailing)
                }.padding(.horizontal, 8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(visibleModels, id: \.self) { model in
                            HStack(spacing: 8) {
                                Toggle(model, isOn: Binding(get: { selected.contains(model) || configured.contains(model) }, set: { on in if on { selected.insert(model) } else { selected.remove(model) } }))
                                    .labelsHidden().toggleStyle(.checkbox).frame(width: 60, alignment: .leading).disabled(configured.contains(model) || adding)
                                Text(model).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).help(model)
                                Text(configured.contains(model) ? L("Configured") : L("Not added")).font(.caption).foregroundStyle(.secondary).frame(width: 88, alignment: .trailing)
                            }.font(.system(size: 12, design: .monospaced))
                        }
                    }.padding(8)
                }.frame(minHeight: 160, maxHeight: .infinity)
            }
            Text(L(note)).font(.system(size: 11)).foregroundStyle(.secondary)
            InlineError(error: failure ?? state.error)
            HStack {
                if failure != nil { Button(L("Retry")) { Task { await fetch() } } }
                Spacer()
                Button(L("Close")) { dismiss() }.disabled(adding).keyboardShortcut(.cancelAction)
                Button(L("Add {0} models", selected.count)) { Task { await add() } }
                    .buttonStyle(.borderedProminent).disabled(loading || adding || selected.isEmpty)
            }
        }.padding(28).frame(width: 670, height: 570).tint(accent).interactiveDismissDisabled(adding)
            .task { await fetch() }
    }

    private func fetch() async {
        if state.preview {
            models = ["model-10", "model-2", "reasoning-large", "coding-large"]
            loading = false; note = "Demo preview · No endpoint requests"; return
        }
        loading = true; failure = nil
        defer { loading = false }
        do {
            let data = try await Bridge.call(["action": "discover", "provider": provider.id])
            let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            models = result?["models"] as? [String] ?? []
            note = result?["message"] as? String ?? "Endpoint models fetched."
        } catch { failure = error.localizedDescription }
    }

    private func add() async {
        adding = true
        defer { adding = false }
        let ok = await state.perform(["action": "batch_models", "operation": "add", "provider": provider.id,
                                      "models": selected.sorted(), "revision": state.snapshot.revision])
        if ok { dismiss() }
    }
}
