import AppKit
import SwiftUI

@main
struct UIBehaviorChecks {
    static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw StudioError(message: message) }
    }

    @MainActor
    static func main() {
        do { try checks() }
        catch { fputs("UI check failed: \(error.localizedDescription)\n", stderr); exit(1) }
    }

    @MainActor
    static func checks() throws {
        let savedOverride = I18n.overrideLanguage
        let savedPreference = UserDefaults.standard.string(forKey: "studio.language")
        defer { I18n.overrideLanguage = savedOverride }
        I18n.overrideLanguage = .english
        try require(I18n.resolveLanguage(nil) == .english && I18n.resolveLanguage("unknown") == .english, "fresh or unsupported preferences must default to English")
        try require(I18n.resolveLanguage("zh-Hans") == .simplifiedChinese, "saved language must resolve correctly")
        try require(I18n.catalogs["en"]?.isEmpty == false && I18n.catalogs["zh-Hans"]?.isEmpty == false, "both language catalogs must be loaded")
        let state = StudioState(preview: true)
        var a = state.snapshot.models[0], b = state.snapshot.models[1], c = state.snapshot.models[2]
        a.id = "demo::model-10"; a.modelID = "model-10"; a.context = "9000"; a.favorite = false
        b.id = "demo::model-2"; b.modelID = "model-2"; b.context = "100000"; b.favorite = true
        c.id = "demo::model-1"; c.modelID = "model-1"; c.context = ""; c.favorite = false
        state.snapshot.models = [a, b, c]
        state.selection = "all"
        state.selectedIDs = [a.id, c.id]
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let before = try encoder.encode(state.snapshot)
        state.sortModels(.name)
        try require(state.models.map(\.modelID) == ["model-1", "model-2", "model-10"], "names must use natural numeric order")
        state.sortModels(.name)
        try require(state.models.map(\.modelID) == ["model-10", "model-2", "model-1"], "second click must reverse direction")
        state.sortModels(.context)
        try require(state.models.map(\.context) == ["9000", "100000", ""], "context must sort numerically with inherited values last")
        state.sortModels(.context)
        try require(state.models.map(\.context) == ["100000", "9000", ""], "inherited context must remain last in descending order")
        state.query = "model-1"
        try require(state.models.count == 2, "search must still filter the sorted collection")
        try require(Set(state.selectedRows.map(\.id)) == [a.id, c.id], "sorting and filtering must preserve selected identities for batch actions")
        try require(try encoder.encode(state.snapshot) == before, "sorting must not mutate model records")
        state.query = ""
        var p1 = state.snapshot.providers[0], p2 = state.snapshot.providers[1]
        p1.configuredCount = 9; p2.configuredCount = 100
        state.snapshot.providers = [p1, p2]
        state.sortEndpoints(.modelCount)
        try require(state.filteredProviders.map(\.configuredCount) == [100, 9], "model count must sort by number")
        state.sortEndpoints(.modelCount)
        try require(state.filteredProviders.map(\.configuredCount) == [9, 100], "endpoint second click must reverse")
        let names = ["model-10", "model-2", "model-1"]
        try require(RowSort.discovered(names, configured: [], selected: [], by: .init(.name)) == ["model-1", "model-2", "model-10"], "discovery model ID order")
        try require(RowSort.discovered(names, configured: ["model-10"], selected: [], by: .init(.configured)).first == "model-10", "discovery configured state sort")
        try require(RowSort.discovered(names, configured: [], selected: ["model-2"], by: .init(.selected)).first == "model-2", "discovery selection state sort")

        let snapshotBeforeLanguage = try encoder.encode(state.snapshot)
        let selectedBeforeLanguage = state.selectedIDs
        state.query = "用户 {1}  "
        state.changeLanguage(.simplifiedChinese)
        try require(L("Custom endpoints") == "自定义端点", "Chinese interface label")
        try require(L("The endpoint returned HTTP 401. Check the URL and credentials.") == "端点返回 HTTP 401。请检查地址与凭证。", "formatted adapter errors must translate on display")
        try require(L("Remove {1} models from “{0}”?", "My {1} API", 2) == "从「My {1} API」移除 2 个模型？", "reordered placeholders must preserve user values containing braces")
        try require(L("Unknown adapter detail") == "Unknown adapter detail", "unknown text must fall back intact")
        state.changeLanguage(.english)
        try require(L("Remove {1} models from “{0}”?", "My {1} API", 2) == "Remove 2 models from “My {1} API”?", "English formatting must not substitute inside user values")
        try require(state.query == "用户 {1}  " && state.selectedIDs == selectedBeforeLanguage, "language changes must preserve search and selection")
        try require(try encoder.encode(state.snapshot) == snapshotBeforeLanguage, "language changes must not translate or mutate model data")

        // Exercise actual AppKit typing and caret movement in an unshown window.
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 90), styleMask: [.borderless], backing: .buffered, defer: false)
        let field = EndpointNameField.makeField()
        field.frame = NSRect(x: 20, y: 25, width: 320, height: 26)
        var bound = "测试端点"
        let coordinator = EndpointNameField.Coordinator(Binding(get: { bound }, set: { bound = $0 }))
        field.delegate = coordinator
        field.stringValue = bound
        window.contentView?.addSubview(field)
        field.selectText(nil)
        guard let editor = field.currentEditor() as? NSTextView else { throw StudioError(message: "hidden text field editor did not initialize") }
        editor.setSelectedRange(NSRange(location: (bound as NSString).length, length: 0))
        let width = field.frame.width
        let beforeSpace = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        editor.insertText(" ", replacementRange: editor.selectedRange())
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.03))
        try require(bound == "测试端点 ", "trailing space must reach the binding immediately")
        try require(field.stringValue == "测试端点 ", "trailing space must remain in the native field")
        try require(editor.selectedRange().location == 5, "caret must advance after a space")
        let afterSpace = editor.firstRect(forCharacterRange: editor.selectedRange(), actualRange: nil)
        try require(afterSpace.minX > beforeSpace.minX, "space must visibly move the caret to the right")
        editor.insertText(" A", replacementRange: editor.selectedRange())
        try require(bound == "测试端点  A", "continued typing must preserve both spaces")
        try require(field.frame.width == width && field.alignment == .left, "editing width must not collapse around trailing whitespace")

        // Check an actual SwiftUI editor update, including its in-progress native field.
        let editState = StudioState(preview: true)
        let host = NSHostingView(rootView: ProviderEditor(state: editState, provider: editState.snapshot.providers[0]))
        let editWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 630, height: 690), styleMask: [.borderless], backing: .buffered, defer: false)
        editWindow.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        func nameField(in view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == "endpoint-display-name" { return field }
            return view.subviews.compactMap { nameField(in: $0) }.first
        }
        guard let draftField = nameField(in: host) else { throw StudioError(message: "endpoint editor field did not mount") }
        draftField.selectText(nil)
        guard let draftEditor = draftField.currentEditor() as? NSTextView else { throw StudioError(message: "endpoint editor did not become editable") }
        draftEditor.insertText("测试端点 {1}  ", replacementRange: NSRange(location: 0, length: (draftField.stringValue as NSString).length))
        let draftCaret = draftEditor.selectedRange()
        editState.changeLanguage(.simplifiedChinese)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try require(nameField(in: host) === draftField, "language change must preserve native editor identity")
        try require(draftField.stringValue == "测试端点 {1}  " && draftEditor.selectedRange() == draftCaret, "language change must preserve draft text and caret")
        try require(draftField.placeholderString == "输入端点显示名称" && draftField.accessibilityLabel() == "显示名称", "native placeholder and accessibility label must change language")
        editState.changeLanguage(.english)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))
        try require(draftField.placeholderString == "Enter a display name", "switching back must update the native placeholder")
        try require(draftField.stringValue == "测试端点 {1}  ", "switching back must retain the unsaved draft")
        try require(UserDefaults.standard.string(forKey: "studio.language") == savedPreference, "preview tests must not persist user preferences")
        print("UI behavior checks passed: sorting/search/selection/localization/fallback/placeholders/native typing/draft and caret preservation")
    }
}
