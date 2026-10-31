import SwiftUI
import Observation
import SeekCore

@MainActor
@Observable
final class Haptics {
    static let shared = Haptics()
    private(set) var preferences: HapticPreferences
    private let defaults: UserDefaults
    private let feedback = UIImpactFeedbackGenerator(style: .soft)
    private var lastInteraction: TimeInterval = 0
    private var lastGeneration: TimeInterval = 0

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: "haptics.preferences")
            .flatMap { try? JSONDecoder().decode(HapticPreferences.self, from: $0) } ?? HapticPreferences()
    }

    func binding(_ key: WritableKeyPath<HapticPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { self.preferences[keyPath: key] }, set: {
            self.preferences[keyPath: key] = $0; self.save()
        })
    }
    func setIntensity(_ value: Double) {
        preferences.intensity = value.isFinite ? min(1, max(0, value)) : 0.6
        save()
    }
    private func save() {
        if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "haptics.preferences") }
    }

    func play(_ category: HapticCategory = .general, scale: Double = 1) {
        guard preferences.allows(category), UIApplication.shared.applicationState == .active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if category == .generation {
            guard now - lastGeneration >= 0.18, now - lastInteraction >= 0.12 else { return }
            lastGeneration = now
        } else {
            guard now - lastInteraction >= 0.06 else { return }
            lastInteraction = now
        }
        feedback.prepare()
        feedback.impactOccurred(intensity: preferences.effectiveIntensity * min(1, max(0, scale)))
    }
}

