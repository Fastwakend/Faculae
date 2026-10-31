import Foundation

public enum HapticCategory: String, CaseIterable, Sendable {
    case general, switches, sidebar, listItem, card, generation
}

public struct HapticPreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var switches = true
    public var sidebar = true
    public var listItems = true
    public var cards = true
    public var generation = true
    public var intensity = 0.6
    public init() {}

    public func allows(_ category: HapticCategory) -> Bool {
        guard enabled, effectiveIntensity > 0 else { return false }
        switch category {
        case .general: return true
        case .switches: return switches
        case .sidebar: return sidebar
        case .listItem: return listItems
        case .card: return cards
        case .generation: return generation
        }
    }
    public var effectiveIntensity: Double { intensity.isFinite ? min(1, max(0, intensity)) : 0.6 }
}
