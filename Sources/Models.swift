import Foundation

struct Provider: Codable, Identifiable {
    var id: String
    var slug: String
    var name: String
    var baseURL: String
    var apiMode: String
    var defaultModel: String
    var discover: Bool
    var context: String
    var keyEnv: String
    var hasKey: Bool
    var editable: Bool
    var configuredCount: Int
    var requestTimeout = ""
    var staleTimeout = ""

    static let empty = Provider(id: "", slug: "", name: "", baseURL: "", apiMode: "chat_completions", defaultModel: "", discover: false, context: "", keyEnv: "", hasKey: false, editable: true, configuredCount: 0)
}

struct ModelRow: Codable, Identifiable {
    var id: String
    var preferenceModel: String
    var providerID: String
    var providerName: String
    var slug: String
    var modelID: String
    var context: String
    var favorite: Bool
    var visible: Bool
    var configured: Bool
    var available: Bool
    var editable: Bool
    var isDefault: Bool
    var requestTimeout = ""
    var staleTimeout = ""
    var presetEffort = ""
    var presetTier = ""
}

struct CatalogProvider: Codable {
    var slug: String
    var name: String
    var models: [String]
    var featured_models: [String]
    var custom: Bool
}

struct Snapshot: Codable {
    var home: String
    var root: String
    var revision: String
    var preferencesRevision: Int
    var providers: [Provider]
    var models: [ModelRow]
    var favorites: [String]
    var catalog: [CatalogProvider]
    var live: Bool
    var note: String
    var defaultProvider: String
    var defaultModel: String
    var legacyCount: Int

    static let empty = Snapshot(home: "", root: "", revision: "", preferencesRevision: 0, providers: [], models: [], favorites: [], catalog: [], live: false, note: "Loading local Hermes…", defaultProvider: "", defaultModel: "", legacyCount: 0)
    static var demo: Snapshot {
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path
        var p = Provider.empty
        p.id = "personal-api"; p.slug = p.id; p.name = "Personal API"
        p.baseURL = "https://api.example.com/v1"; p.defaultModel = "reasoning-large"; p.hasKey = true
        p.keyEnv = "HERMES_CUSTOM_PERSONAL_API_KEY"; p.configuredCount = 6
        var p2 = p
        p2.id = "example-api"; p2.slug = p2.id; p2.name = "Example API"; p2.configuredCount = 2
        p2.baseURL = "https://example.com/compatible-mode/v1"; p2.defaultModel = "chat-large"
        var p3 = p
        p3.id = "local-models"; p3.slug = p3.id; p3.name = "Local inference"; p3.discover = true; p3.configuredCount = 1
        p3.baseURL = "http://127.0.0.1:8080/v1"; p3.defaultModel = "local-model"
        let names = ["reasoning-large", "coding-large", "chat-small", "vision-large", "embedding-small", "chat-large"]
        var rows = names.enumerated().map { i, m in
            ModelRow(id: p.id + "::" + m, preferenceModel: m, providerID: p.id, providerName: p.name, slug: p.slug, modelID: m, context: i == 0 ? "500000" : "", favorite: i < 2, visible: i < 4, configured: true, available: true, editable: true, isDefault: i == 0)
        }
        for (provider, models) in [(p2, ["chat-large", "chat-small"]), (p3, ["local-model"])] {
            rows += models.map { m in ModelRow(id: provider.slug + "::" + m, preferenceModel: m, providerID: provider.id, providerName: provider.name, slug: provider.slug, modelID: m, context: "", favorite: false, visible: true, configured: true, available: true, editable: true, isDefault: m == provider.defaultModel) }
        }
        return Snapshot(home: home, root: home, revision: "demo", preferencesRevision: 1, providers: [p, p2, p3], models: rows, favorites: rows.filter(\.favorite).map(\.id), catalog: [], live: true, note: "Demo preview · Your configuration is untouched", defaultProvider: p.id, defaultModel: p.defaultModel, legacyCount: 0)
    }
}

struct StudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum Bridge {
    static var home: String = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes").path

    static func resource(_ name: String) -> URL {
        Bundle.main.resourceURL!.appendingPathComponent(name)
    }

    static func python() throws -> String {
        let user = FileManager.default.homeDirectoryForCurrentUser.path
        // Release bundles carry their own relocatable interpreter.
        var candidates: [String] = [resource("Python/bin/python3").path]
        if let data = try? Data(contentsOf: resource("runtime.json")),
           let cfg = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let executable = cfg["python"] {
            candidates.append(executable.hasPrefix("/") ? executable : resource(executable).path)
        }
        if let override = ProcessInfo.processInfo.environment["STUDIO_PYTHON"], !override.isEmpty { candidates.insert(override, at: 0) }
        candidates += [user + "/.hermes/hermes-agent/.venv/bin/python", user + "/miniforge3/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw StudioError(message: "No local Python runtime was found. Install or repair Hermes first.")
        }
        return path
    }

    static func run(_ request: [String: Any]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try python())
        process.arguments = ["-I", "-B", resource("bridge.py").path, "--home", home]
        process.currentDirectoryURL = resource("")
        var env = ProcessInfo.processInfo.environment
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        env.removeValue(forKey: "PYTHONPATH")
        env.removeValue(forKey: "PYTHONHOME")
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        let payload = try JSONSerialization.data(withJSONObject: request)
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timeout)
        input.fileHandleForWriting.write(payload)
        try? input.fileHandleForWriting.close()
        // Consume stdout before waiting so large model catalogs cannot fill the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw StudioError(message: "The local adapter could not complete the operation. Check your Python environment or refresh later.")
        }
        guard object["ok"] as? Bool == true, let result = object["result"] else {
            throw StudioError(message: object["error"] as? String ?? "The operation could not be completed. Refresh and try again.")
        }
        return try JSONSerialization.data(withJSONObject: result)
    }

    static func call(_ request: [String: Any]) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try run(request)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}
