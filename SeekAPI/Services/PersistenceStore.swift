import Foundation
import SeekCore

struct AppSnapshot: Codable {
    var version = 3
    var profiles: [APIProfile]
    var conversations: [Conversation]
    var selectedProfileID: UUID
    var selectedConversationID: UUID?
    var usageRecords: [UsageRecord]?
    var balanceConfigurations: [UUID: BalanceConfiguration]?
    var searchProviders: [SearchProvider]?
    var selectedSearchProviderID: UUID?
}

struct PersistenceStore {
    private var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SeekAPI", isDirectory: true)
    }
    private var file: URL { folder.appendingPathComponent("state.json") }

    func load() throws -> AppSnapshot? {
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let snapshot = try JSONDecoder().decode(AppSnapshot.self, from: Data(contentsOf: file))
        guard (1...3).contains(snapshot.version), !snapshot.profiles.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }

    func save(_ snapshot: AppSnapshot) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var location = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try location.setResourceValues(values)
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
