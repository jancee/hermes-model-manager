import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow?
    var languageObserver: NSObjectProtocol?
    let state = StudioState()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = L("Hermes Model Studio")
        window.minSize = NSSize(width: 1000, height: 690)
        window.contentView = NSHostingView(rootView: StudioView(state: state))
        window.center(); window.delegate = self
        window.setFrameAutosaveName("HermesModelStudioMain")
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        buildMenu()
        languageObserver = NotificationCenter.default.addObserver(forName: .studioLanguageChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.window?.title = L("Hermes Model Studio")
                self?.buildMenu()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    private func buildMenu() {
        let menu = NSMenu()
        let app = NSMenuItem(); let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("About Hermes Model Studio"), action: #selector(about), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: L("Quit Hermes Model Studio"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        app.submenu = appMenu; menu.addItem(app)
        let edit = NSMenuItem(); let editMenu = NSMenu(title: L("Edit"))
        for (title, selector, key) in [(L("Undo"), "undo:", "z"), (L("Cut"), "cut:", "x"), (L("Copy"), "copy:", "c"), (L("Paste"), "paste:", "v"), (L("Select All"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        edit.submenu = editMenu; menu.addItem(edit)
        let view = NSMenuItem(); let viewMenu = NSMenu(title: L("View"))
        viewMenu.addItem(withTitle: L("Refresh model catalog"), action: #selector(refresh), keyEquivalent: "r")
        view.submenu = viewMenu; menu.addItem(view)
        let languageItem = NSMenuItem(); let languageMenu = NSMenu(title: L("Language"))
        let english = languageMenu.addItem(withTitle: AppLanguage.english.displayName, action: #selector(useEnglish), keyEquivalent: "")
        english.target = self; english.state = I18n.language == .english ? .on : .off
        let chinese = languageMenu.addItem(withTitle: AppLanguage.simplifiedChinese.displayName, action: #selector(useChinese), keyEquivalent: "")
        chinese.target = self; chinese.state = I18n.language == .simplifiedChinese ? .on : .off
        languageItem.submenu = languageMenu; menu.addItem(languageItem)
        NSApp.mainMenu = menu
    }

    @objc private func refresh() { Task { await state.refresh(live: true) } }
    @objc private func useEnglish() { state.changeLanguage(.english) }
    @objc private func useChinese() { state.changeLanguage(.simplifiedChinese) }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: L("Hermes Model Studio"), .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development", .credits: NSAttributedString(string: L("Local LLM endpoints, batch model management, and client presets.\nConfigurations are backed up before saving."))])
    }
}

@MainActor
func renderPreview(_ path: String) throws {
    let state = StudioState(preview: true)
    if CommandLine.arguments.contains("--endpoints") { state.selection = "endpoints" }
    if CommandLine.arguments.contains("--batch") { state.selectedIDs = Set(state.snapshot.models.prefix(3).map(\.id)) }
    if CommandLine.arguments.contains("--sorted") {
        state.sortEndpoints(.modelCount)
        state.sortModels(.context)
        state.sortModels(.context)
    }
    if CommandLine.arguments.contains("--history") {
        var history = state.snapshot.models[0]
        history.id = history.slug + "::retired-model"; history.modelID = "retired-model"; history.preferenceModel = history.modelID
        history.configured = false; history.available = false; history.favorite = true; history.isDefault = false
        history.context = ""
        state.snapshot.models.insert(history, at: 0)
        state.modelSort = .init(.source, direction: .descending)
    }
    let editor = CommandLine.arguments.contains("--provider-editor")
    let discovery = CommandLine.arguments.contains("--discovery")
    let width: CGFloat = editor ? 630 : discovery ? 670 : 1180
    let height: CGFloat = editor ? 690 : discovery ? 570 : 760
    let content: AnyView = editor ? AnyView(ProviderEditor(state: state, provider: state.snapshot.providers[0])) : discovery ? AnyView(DiscoveryView(state: state, provider: state.snapshot.providers[0])) : AnyView(StudioView(state: state))
    let view = content.frame(width: width, height: height).background(Color.white).environment(\.colorScheme, .light).environment(\.controlActiveState, .active)
    // A hidden AppKit host renders native text fields and scroll views, which ImageRenderer omits.
    // This window is never ordered onto the user's desktop.
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
    window.appearance = NSAppearance(named: .aqua)
    window.contentView = host
    host.frame = NSRect(x: 0, y: 0, width: width, height: height)
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.25))
    host.layoutSubtreeIfNeeded()
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
        throw StudioError(message: L("Preview rendering failed."))
    }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw StudioError(message: L("Preview rendering failed."))
    }
    try png.write(to: URL(fileURLWithPath: path))
}

@main
struct StudioApplication {
    @MainActor
    static func main() {
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--language"), args.count > index + 1, let language = AppLanguage(rawValue: args[index + 1]) { I18n.overrideLanguage = language }
        if let index = args.firstIndex(of: "--home"), args.count > index + 1 { Bridge.home = args[index + 1] }
        if let index = args.firstIndex(of: "--preview"), args.count > index + 1 {
            _ = NSApplication.shared
            do { try renderPreview(args[index + 1]); print("preview-rendered") }
            catch { fputs("preview failed\n", stderr); exit(1) }
        } else if args.contains("--self-test") {
            do { try selfTest(); print("native-integration-ok endpoint-crud/model-batch/default/pin/preset/star/history-removal/conflict/readback") }
            catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        } else if args.contains("--check-bridge") {
            do {
                let data = try Bridge.run(["action": "snapshot", "live": args.contains("--live")])
                let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
                print("bridge-ok providers=\(snapshot.providers.count) models=\(snapshot.models.count) favorites=\(snapshot.favorites.count) live=\(snapshot.live)")
            } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = AppDelegate()
            app.delegate = delegate
            app.run()
        }
    }

    static func selfTest() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("hermes-studio-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        Bridge.home = folder.path
        let config = "model: {provider: demo, default: model-a}\nproviders:\n  demo:\n    name: Demo\n    base_url: https://example.com/v1\n    key_env: DEMO_KEY\n    model: model-a\n    discover_models: false\n    models: {model-a: {}, model-b: {}}\n"
        try config.write(to: folder.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8)
        func read() throws -> Snapshot { try JSONDecoder().decode(Snapshot.self, from: Bridge.run(["action": "snapshot"])) }
        let before = try read()
        guard before.models.count == 2 else { throw StudioError(message: "snapshot mismatch") }
        _ = try Bridge.run(["action": "preference", "field": "favorite", "slug": "demo", "model": "model-a", "enabled": true])
        guard try read().favorites == ["demo::model-a"] else { throw StudioError(message: "favorite mismatch") }
        _ = try Bridge.run(["action": "preference", "field": "favorite", "slug": "demo", "model": "model-a", "enabled": false])
        guard try read().favorites.isEmpty else { throw StudioError(message: "unfavorite mismatch") }
        _ = try Bridge.run(["action": "save_model", "provider": "demo", "model": "model-b", "context": "123456", "revision": before.revision])
        guard try read().models.first(where: { $0.modelID == "model-b" })?.context == "123456" else { throw StudioError(message: "model save mismatch") }
        var refused = false
        do { _ = try Bridge.run(["action": "save_model", "provider": "demo", "model": "model-b", "context": "1", "revision": before.revision]) }
        catch { refused = true }
        guard refused else { throw StudioError(message: "stale write was not refused") }
        let newEndpoint: [String: Any] = ["action": "save_provider", "create": true, "provider": "extra-endpoint", "name": "Extra Endpoint",
            "baseURL": "https://example.com/v1", "apiMode": "chat_completions", "discover": false,
            "defaultModel": "new-a", "context": "", "keyEnv": "EXTRA_KEY", "revision": try read().revision]
        _ = try Bridge.run(newEndpoint)
        _ = try Bridge.run(["action": "batch_models", "operation": "add", "provider": "extra-endpoint", "models": ["new-b", "new-c", "new-b"], "revision": try read().revision])
        guard try read().providers.first(where: { $0.id == "extra-endpoint" })?.configuredCount == 3 else { throw StudioError(message: "batch add mismatch") }
        _ = try Bridge.run(["action": "batch_models", "operation": "default", "provider": "extra-endpoint", "models": ["new-b"], "revision": try read().revision])
        _ = try Bridge.run(["action": "batch_models", "operation": "pin", "provider": "extra-endpoint", "models": ["new-b", "new-c"], "defaultModel": "new-b", "revision": try read().revision])
        _ = try Bridge.run(["action": "save_preset", "slug": "extra-endpoint", "model": "new-b", "effort": "high", "tier": "normal"])
        guard try read().models.first(where: { $0.modelID == "new-b" })?.presetEffort == "high" else { throw StudioError(message: "preset mismatch") }
        _ = try Bridge.run(["action": "batch_models", "operation": "remove", "provider": "extra-endpoint", "models": ["new-c"], "revision": try read().revision])
        _ = try Bridge.run(["action": "delete_provider", "provider": "extra-endpoint", "revision": try read().revision])
        guard try !read().providers.contains(where: { $0.id == "extra-endpoint" }) else { throw StudioError(message: "endpoint delete mismatch") }
        _ = try Bridge.run(["action": "preference", "field": "favorite", "slug": "removed", "model": "historic-model", "enabled": true])
        _ = try Bridge.run(["action": "save_preset", "slug": "removed", "model": "historic-model", "effort": "high", "tier": "normal"])
        let configBeforeCleanup = try Data(contentsOf: folder.appendingPathComponent("config.yaml"))
        _ = try Bridge.run(["action": "forget_models", "items": [["slug": "removed", "model": "historic-model"]]])
        guard try !read().models.contains(where: { $0.id == "removed::historic-model" }),
              try Data(contentsOf: folder.appendingPathComponent("config.yaml")) == configBeforeCleanup else { throw StudioError(message: "history cleanup mismatch") }
    }
}
