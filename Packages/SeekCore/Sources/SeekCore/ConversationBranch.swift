import Foundation

public extension Conversation {
    /// Copy an inclusive prefix into an independent conversation. Attachments
    /// keep their file IDs; batch removal already counts references globally.
    func branched(through nodeID: UUID) throws -> Conversation {
        guard let index = messages.firstIndex(where: { $0.id == nodeID }) else {
            throw APIError.provider("分支节点已不存在，请重新选择。")
        }
        let snapshot = messages.prefix(index + 1).map { source -> ChatMessage in
            var message = source
            message.id = UUID()
            if message.status == .streaming { message.status = .stopped }
            message.generationStage = nil
            return message
        }
        var branch = Conversation(title: "分支 · " + String(title.prefix(80)), profileID: profileID,
                                  messages: snapshot, modelID: modelID)
        branch.parentConversationID = id
        branch.parentMessageID = nodeID
        return branch
    }
}
