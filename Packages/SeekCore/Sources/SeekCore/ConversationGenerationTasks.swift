import Foundation
import Observation

/// A request belongs to its conversation, independently of the visible screen.
@MainActor
@Observable
public final class ConversationGenerationTasks {
    private var runIDs: [UUID: UUID] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    public var conversationIDs: Set<UUID> { Set(runIDs.keys) }
    public var isEmpty: Bool { runIDs.isEmpty }
    public init() {}

    public func contains(_ conversationID: UUID?) -> Bool {
        conversationID.map { runIDs[$0] != nil } ?? false
    }
    public func isCurrent(conversationID: UUID, runID: UUID) -> Bool { runIDs[conversationID] == runID }

    @discardableResult
    public func start(conversationID: UUID, runID: UUID, operation: @escaping @MainActor (UUID) async -> Void) -> Bool {
        guard runIDs[conversationID] == nil else { return false }
        runIDs[conversationID] = runID
        tasks[conversationID] = Task { [weak self] in
            await operation(runID)
            self?.finish(conversationID: conversationID, runID: runID)
        }
        return true
    }

    public func finish(conversationID: UUID, runID: UUID) {
        guard isCurrent(conversationID: conversationID, runID: runID) else { return }
        runIDs[conversationID] = nil
        tasks[conversationID] = nil
    }

    public func cancel(_ conversationID: UUID) {
        let task = tasks.removeValue(forKey: conversationID)
        runIDs[conversationID] = nil
        task?.cancel()
    }

    /// Returning the cancelled ID lets the owner persist the partial reply.
    @discardableResult
    public func switchConversation(from: UUID?, to: UUID?, continues: Bool) -> UUID? {
        guard from != to, !continues, let from, contains(from) else { return nil }
        cancel(from)
        return from
    }
}
