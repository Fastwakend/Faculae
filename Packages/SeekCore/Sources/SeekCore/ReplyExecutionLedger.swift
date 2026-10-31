import Foundation

/// Execution grants are distinct from submitted requests. A late scheduler callback
/// must never revive a completed reply or grant time to a different attempt.
public struct ReplyExecutionLedger: Sendable {
    public private(set) var replies: Set<UUID> = []
    public private(set) var requests: [UUID: UUID] = [:]
    public private(set) var running: Set<UUID> = []

    public init() {}

    @discardableResult
    public mutating func begin(_ replyID: UUID) -> Bool { replies.insert(replyID).inserted }

    @discardableResult
    public mutating func prepare(_ replyID: UUID, requestID: UUID) -> Bool {
        guard replies.contains(replyID), requests[replyID] == nil else { return false }
        requests[replyID] = requestID
        return true
    }

    public func matches(_ replyID: UUID, requestID: UUID) -> Bool {
        replies.contains(replyID) && requests[replyID] == requestID
    }

    @discardableResult
    public mutating func accept(_ replyID: UUID, requestID: UUID) -> Bool {
        guard matches(replyID, requestID: requestID) else { return false }
        return running.insert(replyID).inserted
    }

    /// Submission completion may arrive after the launch handler. Do not revoke
    /// a grant already delivered by the system due to an out-of-order callback.
    public mutating func reject(_ replyID: UUID, requestID: UUID) {
        guard matches(replyID, requestID: requestID), !running.contains(replyID) else { return }
        requests[replyID] = nil
    }

    @discardableResult
    public mutating func expire(_ replyID: UUID, requestID: UUID) -> Bool {
        guard matches(replyID, requestID: requestID), running.remove(replyID) != nil else { return false }
        requests[replyID] = nil
        return true
    }

    public mutating func finish(_ replyID: UUID) {
        replies.remove(replyID)
        requests[replyID] = nil
        running.remove(replyID)
    }

    public mutating func releaseContinuedRequests() {
        requests.removeAll()
        running.removeAll()
    }

    public func needsExperiments(backgroundEnabled: Bool, experimentEnabled: Bool) -> Bool {
        backgroundEnabled && experimentEnabled && !replies.isEmpty
    }

    public func unprotectedReplies(inBackground: Bool, backgroundEnabled: Bool,
                                   sharedExecutionAvailable: Bool) -> Set<UUID> {
        guard inBackground else { return [] }
        guard backgroundEnabled else { return replies }
        return sharedExecutionAvailable ? [] : replies.subtracting(running)
    }
}
