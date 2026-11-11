import SwiftUI
import AppKit
import Combine

@MainActor
final class StudioState: ObservableObject {
    @Published var snapshot = Snapshot.empty
    @Published var selection = "endpoints" { didSet { selectedIDs.removeAll() } }
    @Published var selectedIDs = Set<String>()
    @Published var query = ""
    @Published var onlyConfigured = false
    @Published var busy = false
    @Published var receipt = "Loading local Hermes…"
    @Published var error: String?
    @Published var lastBackup = ""
    @Published var connected = false
    @Published var language = I18n.language
    @Published var modelSort = ListSort<ModelSortColumn>(.favorite)
    @Published var endpointSort = ListSort<EndpointSortColumn>(.name)
    let preview: Bool
    private var lastFileStamp = ""

    init(preview: Bool = false) {
        self.preview = preview
        if preview { snapshot = .demo; selection = "personal-api"; receipt = snapshot.note; connected = true }
        else {
            modelSort = .load("studio.sort.models", default: .favorite)
            endpointSort = .load("studio.sort.endpoints", default: .name)
        }
    }

    func changeLanguage(_ language: AppLanguage) {
        I18n.select(language, persist: !preview)
        self.language = language
    }

    var provider: Provider? { snapshot.providers.first { $0.id == selection } }
    var customProviders: [Provider] { RowSort.endpoints(snapshot.providers.filter(\.editable), by: endpointSort) }
    var otherProviders: [Provider] { snapshot.providers.filter { !$0.editable } }
    var selectedRows: [ModelRow] { snapshot.models.filter { selectedIDs.contains($0.id) } }
    var batchProvider: Provider? {
        guard let first = selectedRows.first, first.editable, selectedRows.allSatisfy({ $0.providerID == first.providerID }) else { return nil }
        return snapshot.providers.first { $0.id == first.providerID }
    }
    var filteredProviders: [Provider] {
        customProviders.filter { query.isEmpty || ($0.id + " " + $0.name + " " + $0.baseURL).localizedCaseInsensitiveContains(query) }
    }
    var models: [ModelRow] {
        RowSort.models(snapshot.models.filter { row in
            (selection == "all" || (selection == "favorites" && row.favorite) || selection == row.providerID)
            && (!onlyConfigured || row.configured)
            && (query.isEmpty || (row.modelID + " " + row.providerName).localizedCaseInsensitiveContains(query))
        }, by: modelSort)
    }

    func sortModels(_ column: ModelSortColumn) {
        modelSort.select(column)
        if !preview { modelSort.save("studio.sort.models") }
    }

    func sortEndpoints(_ column: EndpointSortColumn) {
        endpointSort.select(column)
        if !preview { endpointSort.save("studio.sort.endpoints") }
    }

    var selectedHistoryRows: [ModelRow] { selectedRows.filter { !$0.configured && !$0.available } }

    func confirmForgetHistory(_ rows: [ModelRow]) {
        guard !rows.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("Forget history for {0} models?", rows.count)
        alert.informativeText = L("This clears these models' client favorites, visibility records, and reasoning presets. Endpoint and model configurations are preserved, and the preferences file is backed up first. Models can be added again if they return to the endpoint catalog.")
        alert.addButton(withTitle: L("Forget history")); alert.addButton(withTitle: L("Cancel")); alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let items = rows.map { ["slug": $0.slug, "model": $0.modelID] }
        Task {
            if await perform(["action": "forget_models", "items": items, "catalog": catalogObject]) {
                selectedIDs.subtract(rows.map(\.id))
            }
        }
    }

    var catalogObject: Any {
        (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot.catalog))) ?? []
    }

    private var fileStamp: String {
        let root = snapshot.root.isEmpty ? Bridge.home : snapshot.root
        return [Bridge.home + "/config.yaml", Bridge.home + "/.env", root + "/ui-preferences.json"].map { path in
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return "missing" }
            return "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes[.size] ?? 0)"
        }.joined(separator: "|")
    }

    func refresh(live: Bool = false, silent: Bool = false) async {
        guard !preview, !busy else { return }
        let stamp = fileStamp
        if silent && stamp == lastFileStamp { return }
        busy = true
        defer { busy = false }
        do {
            let data = try await Bridge.call(["action": "snapshot", "live": live, "catalog": catalogObject])
            snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
            lastFileStamp = stamp
            if live { connected = snapshot.live }
            if !silent { receipt = snapshot.note; error = nil }
        } catch {
            self.error = error.localizedDescription
        }
    }

    @discardableResult
    func perform(_ request: [String: Any]) async -> Bool {
        guard !preview, !busy else { return false }
        busy = true; error = nil
        var resultMessage = "Saved."
        do {
            let data = try await Bridge.call(request)
            if let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                resultMessage = result["message"] as? String ?? resultMessage
                if let path = result["backup"] as? String, !path.isEmpty { lastBackup = path }
            }
            let stamp = fileStamp
            let fresh = try await Bridge.call(["action": "snapshot", "catalog": catalogObject])
            snapshot = try JSONDecoder().decode(Snapshot.self, from: fresh)
            lastFileStamp = stamp
            receipt = resultMessage
            busy = false
            return true
        } catch {
            self.error = error.localizedDescription; busy = false
            return false
        }
    }

    func toggle(_ row: ModelRow, field: String) {
        let enabled = field == "favorite" ? !row.favorite : !row.visible
        let models = enabled ? [row.preferenceModel] : Array(Set([row.preferenceModel, row.modelID]))
        let items = models.map { ["slug": row.slug, "model": $0] }
        Task {
            await perform(["action": "preference", "items": items,
                           "field": field, "enabled": enabled,
                           "catalog": catalogObject])
        }
    }

    func batchPreference(field: String, enabled: Bool) {
        let items = selectedRows.flatMap { row in
            (enabled ? [row.preferenceModel] : Array(Set([row.preferenceModel, row.modelID]))).map { ["slug": row.slug, "model": $0] }
        }
        guard !items.isEmpty else { return }
        Task { await perform(["action": "preference", "items": items, "field": field, "enabled": enabled, "catalog": catalogObject]) }
    }

    func setDefault(_ row: ModelRow) {
        Task { await perform(["action": "batch_models", "operation": "default", "provider": row.providerID, "models": [row.modelID], "revision": snapshot.revision]) }
    }

    func confirmBatchRemove() {
        guard let provider = batchProvider, !selectedRows.isEmpty else { return }
        let models = selectedRows.map(\.modelID)
        let alert = NSAlert()
        alert.messageText = L("Remove {1} models from “{0}”?", provider.name, models.count)
        alert.informativeText = L("These models will be removed from the manual list. Favorites are preserved, and automatic discovery may list them again. If any model is referenced by a default setting or task, the entire batch will be rejected.")
        alert.addButton(withTitle: L("Remove selected models")); alert.addButton(withTitle: L("Cancel")); alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await perform(["action": "batch_models", "operation": "remove", "provider": provider.id, "models": models, "revision": snapshot.revision]) { selectedIDs.removeAll() }
        }
    }

    func confirmDeleteModel(_ row: ModelRow) {
        let alert = NSAlert()
        alert.messageText = L("Remove {0} from the endpoint configuration?", row.modelID)
        alert.informativeText = L("Favorites are preserved. Automatic discovery may list this model again. The original configuration will be backed up.")
        alert.addButton(withTitle: L("Remove model")); alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await perform(["action": "delete_model", "provider": row.providerID, "model": row.modelID, "revision": snapshot.revision]) }
    }

    func confirmDeleteProvider(_ p: Provider) {
        let alert = NSAlert()
        alert.messageText = L("Remove endpoint “{0}”?", p.name)
        alert.informativeText = L("The endpoint and its model list will be removed from the configuration. Its API key and favorites are preserved, and the configuration is backed up first. Endpoints referenced by a default model or task cannot be removed.")
        alert.addButton(withTitle: L("Remove endpoint")); alert.addButton(withTitle: L("Cancel"))
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task {
            if await perform(["action": "delete_provider", "provider": p.id, "revision": snapshot.revision]) { selection = "endpoints" }
        }
    }
}
