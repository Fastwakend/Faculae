import XCTest
@testable import SeekCore

final class ConversationGenerationTests: XCTestCase {
    @MainActor func testSwitchingConversationKeepsOriginalTaskAndAllowsAnotherReply() async {
        let tasks = ConversationGenerationTasks()
        let a = UUID(), b = UUID(), first = UUID(), second = UUID()
        var finished = Set<UUID>()
        tasks.start(conversationID: a, runID: first) { _ in
            await Task.yield()
            if !Task.isCancelled { finished.insert(a) }
        }
        XCTAssertNil(tasks.switchConversation(from: a, to: b, continues: true))
        XCTAssertTrue(tasks.isCurrent(conversationID: a, runID: first))
        XCTAssertTrue(tasks.start(conversationID: b, runID: second) { _ in
            if !Task.isCancelled { finished.insert(b) }
        })
        for _ in 0..<30 { await Task.yield() }
        XCTAssertEqual(finished, [a, b])
        XCTAssertTrue(tasks.isEmpty)
    }

    @MainActor func testSwitchOptionOffCancelsOnlyTheConversationBeingLeft() async {
        let tasks = ConversationGenerationTasks()
        let a = UUID(), b = UUID(), first = UUID(), second = UUID()
        tasks.start(conversationID: a, runID: first) { _ in try? await Task.sleep(for: .seconds(10)) }
        tasks.start(conversationID: b, runID: second) { _ in try? await Task.sleep(for: .seconds(10)) }
        XCTAssertEqual(tasks.switchConversation(from: a, to: b, continues: false), a)
        XCTAssertFalse(tasks.contains(a))
        XCTAssertTrue(tasks.isCurrent(conversationID: b, runID: second))
        tasks.cancel(b)
    }

    @MainActor func testSameConversationSelectionAndLateCompletionCannotCancelNewRun() {
        let tasks = ConversationGenerationTasks(), chat = UUID(), old = UUID(), new = UUID()
        tasks.start(conversationID: chat, runID: old) { _ in }
        XCTAssertNil(tasks.switchConversation(from: chat, to: chat, continues: false))
        XCTAssertFalse(tasks.start(conversationID: chat, runID: UUID()) { _ in })
        tasks.cancel(chat)
        tasks.start(conversationID: chat, runID: new) { _ in }
        tasks.finish(conversationID: chat, runID: old)
        XCTAssertTrue(tasks.isCurrent(conversationID: chat, runID: new))
        tasks.cancel(chat)
    }
}
