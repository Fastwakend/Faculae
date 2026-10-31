import Foundation

/// SwiftUI onMove offsets refer to the original array, including the items
/// being moved. Keep the same semantics in the shared persistence model.
public enum ListOrdering {
    @discardableResult
    public static func move<Element>(_ items: inout [Element], fromOffsets source: IndexSet,
                                     toOffset destination: Int) -> Bool {
        guard !source.isEmpty, (0...items.count).contains(destination),
              source.allSatisfy({ items.indices.contains($0) }) else { return false }
        let insertion = destination - source.filter { $0 < destination }.count
        var order = items.indices.filter { !source.contains($0) }
        order.insert(contentsOf: source, at: insertion)
        guard order != Array(items.indices) else { return false }
        items = order.map { items[$0] }
        return true
    }
}
