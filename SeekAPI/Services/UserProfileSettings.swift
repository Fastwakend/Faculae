import Foundation
import Observation
import SeekCore

@MainActor
@Observable
final class UserProfileSettings {
    private(set) var name = UserDefaults.standard.string(forKey: "identity.username") ?? "本地空间"
    private(set) var avatarID = UserDefaults.standard.string(forKey: "identity.avatarID").flatMap(UUID.init(uuidString:))

    func save(name: String, avatarID: UUID?) throws {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 40 else { throw APIError.provider("用户名最多 40 个字符。") }
        let oldAvatar = self.avatarID
        self.name = trimmed.isEmpty ? "本地空间" : trimmed
        self.avatarID = avatarID
        UserDefaults.standard.set(self.name, forKey: "identity.username")
        UserDefaults.standard.set(avatarID?.uuidString, forKey: "identity.avatarID")
        if let oldAvatar, oldAvatar != avatarID { Task { await ModelIconStore.shared.remove(oldAvatar) } }
    }
}
