import SwiftUI
import AppKit
import Combine

let accent = Color(red: 0.10, green: 0.47, blue: 0.42)
let canvas = Color(nsColor: .windowBackgroundColor)

struct StudioView: View {
    @ObservedObject var state: StudioState
    @State private var providerEditor: Provider?
    @State private var modelEditor: ModelEdit?
    @State private var keyEditor: Provider?
    @State private var discovery: Provider?
    @State private var batchEditor: BatchEdit?
    @State private var presetEditor: ModelRow?
    private let ticker = Timer.publish(every: 4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 232)
            Divider()
            VStack(spacing: 0) {
                header
                if let error = state.error {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                        Text(L(error)).font(.system(size: 12)).textSelection(.enabled)
                        Spacer()
                        Button { state.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                    }.padding(12).background(Color.orange.opacity(0.09))
                }
                if state.snapshot.legacyCount > 0 {
                    Text(L("Legacy endpoint configuration detected. This tool edits the providers format and preserves legacy entries."))
                        .font(.caption).foregroundStyle(.orange).padding(8)
                }
                if let provider = state.provider { providerSummary(provider) }
                searchBar
                if state.selection == "endpoints" {
                    EndpointList(state: state, onEdit: { providerEditor = $0 }, onKey: { keyEditor = $0 }, onDiscover: { discovery = $0 })
                } else {
                    if !state.selectedRows.isEmpty { batchBar }
                    modelList
                }
                footer
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .tint(accent)
        .environment(\.locale, Locale(identifier: state.language.rawValue))
        .frame(minWidth: 1000, minHeight: 660)
        .sheet(item: $providerEditor) { p in ProviderEditor(state: state, provider: p) }
        .sheet(item: $modelEditor) { model in ModelEditor(state: state, edit: model) }
        .sheet(item: $keyEditor) { p in KeyEditor(state: state, provider: p) }
        .sheet(item: $discovery) { p in DiscoveryView(state: state, provider: p) }
        .sheet(item: $batchEditor) { edit in BatchModelEditor(state: state, edit: edit) }
        .sheet(item: $presetEditor) { row in PresetEditor(state: state, model: row) }
        .task { await state.refresh(live: true) }
        .onReceive(ticker) { _ in
            if providerEditor == nil && modelEditor == nil && keyEditor == nil && discovery == nil && batchEditor == nil && presetEditor == nil {
                Task { await state.refresh(silent: true) }
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11).fill(accent.gradient).frame(width: 38, height: 38)
                    Image(systemName: "cpu").font(.system(size: 23)).foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes").font(.system(size: 18, weight: .bold))
                    Text("MODEL STUDIO").font(.system(size: 8, weight: .semibold, design: .rounded)).tracking(2).foregroundStyle(.secondary)
                }
            }.padding(.horizontal, 20).padding(.top, 24).padding(.bottom, 26)
            navRow(L("Custom endpoints"), symbol: "server.rack", id: "endpoints", count: state.customProviders.count)
            navRow(L("All models"), symbol: "square.grid.2x2", id: "all", count: state.snapshot.models.filter(\.available).count)
            navRow(L("Favorites"), symbol: "star", id: "favorites", count: state.snapshot.favorites.count)
            HStack {
                Text(L("My endpoints")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Spacer()
                Button { providerEditor = .empty } label: { Image(systemName: "plus").font(.system(size: 13)) }
                    .buttonStyle(.plain).help(L("Add endpoint")).accessibilityLabel(L("Add endpoint"))
            }.padding(.horizontal, 21).padding(.top, 26).padding(.bottom, 10)
            ScrollView {
                VStack(spacing: 3) {
                    ForEach(state.customProviders) { p in
                        navRow(p.name, symbol: p.discover ? "network" : "server.rack", id: p.id, count: p.configuredCount)
                    }
                    if !state.otherProviders.isEmpty {
                        Text(L("Other client endpoints")).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 21).padding(.top, 20).padding(.bottom, 8)
                        ForEach(state.otherProviders) { p in
                            navRow(p.name, symbol: p.id.hasPrefix("history:") ? "clock.arrow.circlepath" : "cloud", id: p.id, count: nil)
                        }
                    }
                }.padding(.bottom, 12)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Picker(L("Language"), selection: Binding(get: { state.language }, set: { state.changeLanguage($0) })) {
                    ForEach(AppLanguage.allCases) { language in Text(language.displayName).tag(language) }
                }.labelsHidden().help(L("Language changes preserve your edits."))
            }.padding(.horizontal, 20).padding(.bottom, 12)
            Divider().padding(.horizontal, 18)
            HStack(spacing: 7) {
                Circle().fill(accent).frame(width: 6, height: 6)
                VStack(alignment: .leading, spacing: 3) {
                    Text(L("Local Hermes")).font(.system(size: 11, weight: .medium))
                    Text(L("Configuration stays on this Mac")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }.padding(20)
        }
        .background(canvas)
    }

    private func navRow(_ title: String, symbol: String, id: String, count: Int?) -> some View {
        Button { state.selection = id; state.query = "" } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 14)).frame(width: 18)
                Text(title).font(.system(size: 12, weight: state.selection == id ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 3)
                if let count { Text("\(count)").font(.system(size: 10, design: .monospaced)).opacity(0.6) }
            }
            .foregroundStyle(state.selection == id ? accent : Color.primary.opacity(0.80))
            .padding(.horizontal, 11).padding(.vertical, 10)
            .background(state.selection == id ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 10).help(title)
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 7) {
                Text(state.provider?.name ?? (state.selection == "endpoints" ? L("Custom LLM endpoints") : state.selection == "favorites" ? L("Favorites") : L("Model library")))
                    .font(.system(size: 26, weight: .bold)).lineLimit(1)
                Text(state.selection == "endpoints" ? L("Create endpoints and manage their models in one place.") : state.selection == "favorites" ? L("Favorites are shared with Hermes. Keep your frequently used models close at hand.") : L("Manage endpoints, organize models, and keep favorites within reach."))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 16)
            Button { Task { await state.refresh(live: true) } } label: {
                Label(L("Refresh catalog"), systemImage: "arrow.clockwise")
            }.help(L("Read the running Hermes model catalog and latest configuration")).disabled(state.busy)
            if let p = state.provider, p.editable {
                Menu {
                    Button(L("Add one model…")) { modelEditor = ModelEdit(provider: p) }
                    Button(L("Paste model IDs…")) { batchEditor = BatchEdit(provider: p) }
                    Button(L("Fetch endpoint models…")) { discovery = p }
                } label: { Label(L("Add models"), systemImage: "plus") }
                .menuStyle(.borderedButton).disabled(state.busy)
            } else {
                Button { providerEditor = .empty } label: { Label(L("Add endpoint"), systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(state.busy)
            }
        }.padding(.horizontal, 30).padding(.top, 28).padding(.bottom, 23)
    }

    private func providerSummary(_ p: Provider) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack(alignment: .top, spacing: 15) {
                Image(systemName: p.editable ? "point.3.connected.trianglepath.dotted" : "cloud")
                    .font(.system(size: 22)).foregroundStyle(accent).frame(width: 40, height: 42)
                    .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 6) {
                    Text(p.editable ? L("API endpoint") : L("Hermes client endpoint")).font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(p.editable ? p.baseURL : L("Manage favorites and visibility"))
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                if p.editable {
                    Menu {
                        Button(L("Edit endpoint")) { providerEditor = p }
                        Button(L("Set API key…")) { keyEditor = p }
                        Button(L("Fetch endpoint models…")) { discovery = p }
                        Divider()
                        Button(L("Remove endpoint…"), role: .destructive) { state.confirmDeleteProvider(p) }
                    } label: { Label(L("Endpoint settings"), systemImage: "slider.horizontal.3") }.fixedSize().disabled(state.busy)
                }
            }
            if p.editable {
                HStack(spacing: 12) {
                    pill(p.discover ? L("Automatic discovery on") : L("Manual list only"), icon: p.discover ? "sparkle.magnifyingglass" : "list.bullet", color: accent)
                    pill(p.apiMode.isEmpty ? L("Auto protocol") : modeLabel(p.apiMode), icon: "arrow.left.arrow.right", color: .secondary)
                    pill(p.hasKey ? L("Key configured") : L("No key detected"), icon: p.hasKey ? "key.fill" : "key", color: p.hasKey ? .secondary : .orange)
                    Spacer()
                    Button(L("Edit")) { providerEditor = p }.buttonStyle(.link).font(.system(size: 11))
                }
                if p.discover {
                    Text(L("Automatic discovery may list every endpoint model. Disable it to use only your manual list."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(18).background(canvas.opacity(0.65), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        .padding(.horizontal, 30).padding(.bottom, 23)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(state.selection == "endpoints" ? L("Search endpoint names, IDs, or URLs") : L("Search models or endpoints"), text: $state.query).textFieldStyle(.plain)
                    .accessibilityLabel(L("Search models or endpoints"))
                if !state.query.isEmpty { Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }.buttonStyle(.plain) }
            }.padding(10).background(canvas, in: RoundedRectangle(cornerRadius: 8))
            if state.selection != "endpoints" { Toggle(L("Manual only"), isOn: $state.onlyConfigured).toggleStyle(.checkbox).font(.system(size: 11)).padding(.leading, 10) }
            Text(state.selection == "endpoints" ? L("{0} endpoints", state.filteredProviders.count) : L("{0} models", state.models.count)).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 75, alignment: .trailing)
        }.padding(.horizontal, 30).padding(.bottom, 14)
    }

    private var modelList: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Toggle(L("Select all current results"), isOn: Binding(get: { !state.models.isEmpty && state.models.allSatisfy { state.selectedIDs.contains($0.id) } }, set: { on in
                    if on { state.selectedIDs.formUnion(state.models.map(\.id)) }
                    else { state.selectedIDs.subtract(state.models.map(\.id)) }
                })).labelsHidden().toggleStyle(.checkbox).frame(width: 20).disabled(state.busy)
                SortHeader(title: L("Star"), column: .favorite, sort: state.modelSort) { state.sortModels(.favorite) }.frame(width: 44)
                HStack(spacing: 8) {
                    SortHeader(title: L("Model"), column: .name, sort: state.modelSort) { state.sortModels(.name) }
                    SortHeader(title: L("Endpoint"), column: .provider, sort: state.modelSort) { state.sortModels(.provider) }
                    SortHeader(title: L("Source"), column: .source, sort: state.modelSort) { state.sortModels(.source) }
                }.padding(.leading, 8).frame(maxWidth: .infinity, alignment: .leading)
                SortHeader(title: L("Context"), column: .context, sort: state.modelSort) { state.sortModels(.context) }.frame(width: 80, alignment: .trailing)
                SortHeader(title: L("Visible"), column: .visible, sort: state.modelSort) { state.sortModels(.visible) }.frame(width: 86)
                Text(L("Actions")).frame(width: 48)
            }.font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                .padding(.horizontal, 12).padding(.vertical, 10).background(canvas.opacity(0.65))
            Divider()
            if state.models.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: state.selection == "favorites" ? "star" : "square.stack.3d.up").font(.system(size: 32, weight: .light)).foregroundStyle(accent.opacity(0.7))
                    Text(state.query.isEmpty ? L("No models here yet") : L("No matching models")).font(.system(size: 15, weight: .semibold))
                    Text(state.selection == "favorites" ? L("Click a model's star to add it to your favorites.") : L("Choose an endpoint to add models, or adjust your search."))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(state.models) { row in
                            modelRow(row)
                            Divider().padding(.leading, 52)
                        }
                    }
                }
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.09)))
            .padding(.horizontal, 30).padding(.bottom, 20)
    }

    private func modelRow(_ row: ModelRow) -> some View {
        HStack(spacing: 0) {
            Toggle(L("Select {0}", row.modelID), isOn: Binding(get: { state.selectedIDs.contains(row.id) }, set: { on in
                if on { state.selectedIDs.insert(row.id) } else { state.selectedIDs.remove(row.id) }
            })).labelsHidden().toggleStyle(.checkbox).frame(width: 20).disabled(state.busy)
            Button { state.toggle(row, field: "favorite") } label: {
                Image(systemName: row.favorite ? "star.fill" : "star")
                    .font(.system(size: 17, weight: .regular)).foregroundStyle(row.favorite ? Color(red: 0.85, green: 0.57, blue: 0.12) : Color.secondary.opacity(0.45))
                    .frame(width: 44, height: 36).contentShape(Rectangle())
            }.buttonStyle(.plain).help(row.favorite ? L("Unstar") : L("Add to Hermes favorites"))
                .accessibilityLabel((row.favorite ? L("Unstar ") : L("Star ")) + row.modelID).disabled(state.busy)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(row.modelID).font(.system(size: 12, weight: .medium, design: .monospaced)).lineLimit(1).textSelection(.enabled)
                    if row.isDefault { modelBadge(L("Default"), color: accent) }
                    if !row.available {
                        modelBadge(row.configured ? L("Not in catalog") : L("History"), color: .orange)
                            .help(row.configured ? L("This ID remains in the manual configuration but was not returned by the current Hermes catalog. You can unstar it, hide it, or remove it from the configuration.") : L("A historical favorite retained by the client. You can unstar it, hide it, or forget its history."))
                    }
                }
                HStack(spacing: 5) {
                    Text(row.providerName).lineLimit(1)
                    Text("·")
                    Text(row.configured ? L("Manual configuration") : (row.available ? L("Catalog model") : L("Saved favorite")))
                    if !row.presetEffort.isEmpty { Text(L("· Reasoning: {0}", row.presetEffort)).foregroundStyle(accent) }
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 8)
            Text(contextLabel(row.context)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            Toggle(L("Show {0}", row.modelID), isOn: Binding(get: { row.visible }, set: { _ in state.toggle(row, field: "visible") }))
                .labelsHidden().toggleStyle(.switch).controlSize(.mini).frame(width: 86).disabled(state.busy)
                .help(L("Control visibility in the Hermes model menu"))
            Menu {
                Button(row.favorite ? L("Unstar") : L("Star model")) { state.toggle(row, field: "favorite") }
                Button(row.visible ? L("Hide in Hermes") : L("Show in Hermes")) { state.toggle(row, field: "visible") }
                Divider()
                if row.editable, let p = state.snapshot.providers.first(where: { $0.id == row.providerID }) {
                    Button(row.configured ? L("Edit model…") : L("Add to manual list…")) { modelEditor = ModelEdit(provider: p, row: row) }
                    Button(L("Set as endpoint default")) { state.setDefault(row) }.disabled(row.isDefault)
                    if row.configured { Button(L("Remove from configuration…"), role: .destructive) { state.confirmDeleteModel(row) } }
                }
                if !row.configured && !row.available {
                    Button(L("Forget history…"), role: .destructive) { state.confirmForgetHistory([row]) }
                }
                Button(L("Client reasoning preset…")) { presetEditor = row }
                Button(L("Copy model ID")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(row.modelID, forType: .string) }
            } label: { Image(systemName: "ellipsis").frame(width: 24, height: 26) }
                .menuStyle(.borderlessButton).frame(width: 48).disabled(state.busy)
        }.padding(.horizontal, 12).padding(.vertical, 12)
            .background(state.selectedIDs.contains(row.id) ? accent.opacity(0.06) : row.favorite ? Color.yellow.opacity(0.025) : Color.clear)
    }

    private var batchBar: some View {
        HStack(spacing: 12) {
            Text(L("{0} selected", state.selectedRows.count)).font(.system(size: 11, weight: .semibold)).foregroundStyle(accent)
            Menu(L("Favorites & visibility")) {
                Button(L("Star selected")) { state.batchPreference(field: "favorite", enabled: true) }
                Button(L("Unstar selected")) { state.batchPreference(field: "favorite", enabled: false) }
                Divider()
                Button(L("Show selected")) { state.batchPreference(field: "visible", enabled: true) }
                Button(L("Hide selected")) { state.batchPreference(field: "visible", enabled: false) }
            }.fixedSize()
            if let p = state.batchProvider {
                Menu(L("Model list")) {
                    Button(L("Add to manual list")) {
                        Task { await state.perform(["action": "batch_models", "operation": "add", "provider": p.id, "models": state.selectedRows.map(\.modelID), "revision": state.snapshot.revision]) }
                    }
                    Button(L("Keep only selected models…")) { batchEditor = BatchEdit(provider: p, operation: "pin", models: state.selectedRows.map(\.modelID)) }
                    Divider()
                    Button(L("Remove selected from configuration…"), role: .destructive) { state.confirmBatchRemove() }
                        .disabled(!state.selectedRows.allSatisfy(\.configured))
                }.fixedSize()
            }
            if !state.selectedHistoryRows.isEmpty {
                Button(L("Forget history ({0})", state.selectedHistoryRows.count)) { state.confirmForgetHistory(state.selectedHistoryRows) }.buttonStyle(.link)
            }
            Spacer()
            Button(L("Copy IDs")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(state.selectedRows.map(\.modelID).joined(separator: "\n"), forType: .string)
            }.buttonStyle(.link)
            Button(L("Clear selection")) { state.selectedIDs.removeAll() }.buttonStyle(.link)
        }.font(.system(size: 11)).padding(.horizontal, 12).padding(.vertical, 10)
            .background(accent.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            .padding(.horizontal, 30).padding(.bottom, 10).disabled(state.busy)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if state.busy { ProgressView().controlSize(.mini) }
            else { Image(systemName: state.error == nil ? "checkmark.circle" : "exclamationmark.circle").foregroundStyle(state.error == nil ? accent : .orange) }
            Text(L(state.receipt)).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            Spacer()
            if !state.lastBackup.isEmpty {
                Button(L("Show backup")) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: state.lastBackup)]) }
                    .buttonStyle(.link).font(.system(size: 10))
            }
            Text(L("Automatic backups · Saved locally")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(.horizontal, 30).padding(.vertical, 13).background(canvas.opacity(0.45))
    }
}

func modeLabel(_ mode: String) -> String {
    ["chat_completions": "Chat Completions", "codex_responses": "Codex Responses", "responses": "Responses", "anthropic_messages": "Anthropic Messages"][mode] ?? mode
}

func contextLabel(_ context: String) -> String {
    guard let n = Double(context), n > 0 else { return L("Automatic") }
    return n >= 1_000_000 ? String(format: "%.2gM", n / 1_000_000) : (n >= 1000 ? String(format: "%.0fK", n / 1000) : context)
}

func pill(_ text: String, icon: String, color: Color) -> some View {
    Label(text, systemImage: icon).font(.system(size: 10)).foregroundStyle(color)
        .padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.07), in: Capsule())
}

func modelBadge(_ text: String, color: Color) -> some View {
    Text(text).font(.system(size: 8, weight: .medium)).foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 3).background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
}
