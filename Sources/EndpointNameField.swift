import AppKit
import SwiftUI

/// A normal editing surface with reserved width. Form's automatic trailing-aligned
/// text presentation can collapse the visible space at the end of an in-progress value.
struct EndpointNameField: NSViewRepresentable {
    @Binding var text: String
    // A stored language dependency makes SwiftUI update native labels even when
    // the text binding itself has not changed.
    var language: AppLanguage

    static func makeField() -> NSTextField {
        let field = NSTextField()
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.textColor = .labelColor
        field.font = .systemFont(ofSize: 13)
        field.alignment = .left
        field.lineBreakMode = .byClipping
        field.placeholderString = L("Enter a display name")
        field.identifier = NSUserInterfaceItemIdentifier("endpoint-display-name")
        field.setAccessibilityLabel(L("Display name"))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        if let cell = field.cell as? NSTextFieldCell {
            cell.usesSingleLineMode = true
            cell.isScrollable = true
        }
        return field
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = Self.makeField()
        field.stringValue = text
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        context.coordinator.value = $text
        field.placeholderString = L("Enter a display name")
        field.setAccessibilityLabel(L("Display name"))
        // Avoid replacing the field editor's string or selection on each keystroke.
        if field.stringValue != text { field.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator($text) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var value: Binding<String>
        init(_ value: Binding<String>) { self.value = value }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            value.wrappedValue = field.stringValue
        }
    }
}
