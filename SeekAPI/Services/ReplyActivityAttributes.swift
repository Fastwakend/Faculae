import ActivityKit
import Foundation

/// Compiled into both targets. Never put credentials or reply text in an activity.
struct ReplyActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var tokens: Int
        var estimated: Bool
        var endedAt: Date?
    }
    var replyID: UUID
    var conversationID: UUID
    var modelName: String
    var supplierLogo: String
    var startedAt: Date
}
