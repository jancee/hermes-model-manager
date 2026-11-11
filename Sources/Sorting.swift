import Foundation
import SwiftUI

enum SortDirection: String {
    case ascending, descending
    var arrow: String { self == .ascending ? "chevron.up" : "chevron.down" }
    var label: String { self == .ascending ? L("Ascending") : L("Descending") }
    mutating func toggle() { self = self == .ascending ? .descending : .ascending }
}

protocol SortColumn: RawRepresentable, Equatable where RawValue == String {
    var initialDirection: SortDirection { get }
}

enum ModelSortColumn: String, SortColumn {
    case favorite, name, provider, context, visible, source
    var initialDirection: SortDirection { self == .favorite || self == .visible ? .descending : .ascending }
}

enum EndpointSortColumn: String, SortColumn {
    case name, address, defaultModel, protocolName, modelCount, discover, credential
    var initialDirection: SortDirection { [.modelCount, .discover, .credential].contains(self) ? .descending : .ascending }
}

enum DiscoverySortColumn: String, SortColumn {
    case name, configured, selected
    var initialDirection: SortDirection { self == .name ? .ascending : .descending }
}

struct ListSort<Column: SortColumn>: Equatable {
    var column: Column
    var direction: SortDirection

    init(_ column: Column, direction: SortDirection? = nil) {
        self.column = column; self.direction = direction ?? column.initialDirection
    }

    mutating func select(_ column: Column) {
        if self.column == column { direction.toggle() }
        else { self.column = column; direction = column.initialDirection }
    }

    static func load(_ key: String, default column: Column) -> Self {
        let store = UserDefaults.standard
        return Self(Column(rawValue: store.string(forKey: key + ".column") ?? "") ?? column,
                    direction: SortDirection(rawValue: store.string(forKey: key + ".direction") ?? ""))
    }

    func save(_ key: String) {
        UserDefaults.standard.set(column.rawValue, forKey: key + ".column")
        UserDefaults.standard.set(direction.rawValue, forKey: key + ".direction")
    }
}

enum RowSort {
    private static func text(_ a: String, _ b: String) -> ComparisonResult { a.localizedStandardCompare(b) }
    private static func number<T: Comparable>(_ a: T, _ b: T) -> ComparisonResult { a == b ? .orderedSame : a < b ? .orderedAscending : .orderedDescending }
    private static func flag(_ a: Bool, _ b: Bool) -> ComparisonResult { number(a ? 1 : 0, b ? 1 : 0) }
    private static func ordered(_ primary: ComparisonResult, direction: SortDirection, tie: ComparisonResult) -> Bool {
        if primary == .orderedSame { return tie == .orderedAscending }
        return primary == (direction == .ascending ? .orderedAscending : .orderedDescending)
    }
    private static func context(_ value: String) -> Double? {
        guard let n = Double(value), n.isFinite, n > 0 else { return nil }
        return n
    }
    private static func identity(_ nameA: String, _ idA: String, _ nameB: String, _ idB: String) -> ComparisonResult {
        let byName = text(nameA, nameB)
        if byName != .orderedSame { return byName }
        let byID = text(idA, idB)
        if byID != .orderedSame { return byID }
        return number(idA, idB)
    }

    static func models(_ rows: [ModelRow], by sort: ListSort<ModelSortColumn>) -> [ModelRow] {
        rows.sorted { a, b in
            let result: ComparisonResult
            switch sort.column {
            case .favorite: result = flag(a.favorite, b.favorite)
            case .name: result = text(a.modelID, b.modelID)
            case .provider: result = text(a.providerName, b.providerName)
            case .context:
                let av = context(a.context), bv = context(b.context)
                // An inherited/unknown value has no numeric rank: always keep it after explicit values.
                if (av == nil) != (bv == nil) { return av != nil }
                result = av == nil ? .orderedSame : number(av!, bv!)
            case .visible: result = flag(a.visible, b.visible)
            case .source: result = number(a.configured ? 0 : a.available ? 1 : 2, b.configured ? 0 : b.available ? 1 : 2)
            }
            return ordered(result, direction: sort.direction, tie: identity(a.modelID, a.id, b.modelID, b.id))
        }
    }

    static func endpoints(_ rows: [Provider], by sort: ListSort<EndpointSortColumn>) -> [Provider] {
        rows.sorted { a, b in
            let result: ComparisonResult
            switch sort.column {
            case .name: result = text(a.name, b.name)
            case .address: result = text(a.baseURL, b.baseURL)
            case .defaultModel: result = text(a.defaultModel, b.defaultModel)
            case .protocolName: result = text(a.apiMode, b.apiMode)
            case .modelCount: result = number(a.configuredCount, b.configuredCount)
            case .discover: result = flag(a.discover, b.discover)
            case .credential: result = flag(a.hasKey, b.hasKey)
            }
            return ordered(result, direction: sort.direction, tie: identity(a.name, a.id, b.name, b.id))
        }
    }

    static func discovered(_ models: [String], configured: Set<String>, selected: Set<String>, by sort: ListSort<DiscoverySortColumn>) -> [String] {
        models.sorted { a, b in
            let result: ComparisonResult
            switch sort.column {
            case .name: result = text(a, b)
            case .configured: result = flag(configured.contains(a), configured.contains(b))
            case .selected: result = flag(configured.contains(a) || selected.contains(a), configured.contains(b) || selected.contains(b))
            }
            return ordered(result, direction: sort.direction, tie: identity(a, a, b, b))
        }
    }
}

struct SortHeader<Column: SortColumn>: View {
    let title: String
    let column: Column
    let sort: ListSort<Column>
    let action: () -> Void
    private var active: Bool { sort.column == column }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: active ? sort.direction.arrow : "arrow.up.arrow.down")
                    .font(.system(size: 8, weight: .semibold)).opacity(active ? 1 : 0.35)
            }.font(.system(size: 10, weight: active ? .semibold : .medium))
                .foregroundStyle(active ? accent : Color.secondary).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .help(active ? L("Sorted by {0}, {1}. Click to reverse.", title, sort.direction.label) : L("Sort by {0}", title))
            .accessibilityLabel(title + L(" sort")).accessibilityValue(active ? sort.direction.label : L("Not sorted"))
    }
}
