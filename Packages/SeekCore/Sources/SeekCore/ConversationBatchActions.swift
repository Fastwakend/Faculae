import Foundation

public enum ConversationBatchActions {
    /// Return only orphaned attachments, once per file, after removing the
    /// selected conversations. Surviving transcripts keep shared files alive.
    public static func remove(_ ids: Set<UUID>, from conversations: inout [Conversation]) -> [ChatAttachment] {
        guard !ids.isEmpty else { return [] }
        let candidates = conversations.filter { ids.contains($0.id) }
            .flatMap(\.messages).flatMap { $0.attachments ?? [] }
        conversations.removeAll { ids.contains($0.id) }
        let retained = Set(conversations.flatMap(\.messages).flatMap { $0.attachments ?? [] }.map(\.id))
        var seen: Set<UUID> = []
        return candidates.filter { !retained.contains($0.id) && seen.insert($0.id).inserted }
    }

    public static func setPinned(_ pinned: Bool, ids: Set<UUID>, in conversations: inout [Conversation]) {
        for index in conversations.indices where ids.contains(conversations[index].id) {
            conversations[index].isPinned = pinned
        }
    }
}
