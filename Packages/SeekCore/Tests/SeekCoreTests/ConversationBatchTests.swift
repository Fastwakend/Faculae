import Foundation
import XCTest
@testable import SeekCore

final class ConversationBatchTests: XCTestCase {
    func testDeletingSelectionPreservesUnselectedTranscriptAndRoundTrip() throws {
        let supplier = UUID()
        let first = Conversation(title: "first", profileID: supplier,
            messages: [ChatMessage(role: .assistant, content: "keep content", reasoning: "keep reasoning", model: "m", modelDisplayName: "Display")],
            modelID: UUID())
        let second = Conversation(title: "second", profileID: supplier)
        let third = Conversation(title: "third", profileID: supplier)
        var history = [first, second, third]
        let files = ConversationBatchActions.remove([second.id, UUID()], from: &history)
        XCTAssertEqual(history, [first, third])
        XCTAssertTrue(files.isEmpty)
        let restored = try JSONDecoder().decode([Conversation].self, from: JSONEncoder().encode(history))
        XCTAssertEqual(restored, [first, third])
    }

    func testDeletingMultipleChatsReturnsOrphanedFilesOnceAndKeepsSharedFile() {
        let supplier = UUID()
        let shared = ChatAttachment(name: "shared", mimeType: "image/png", kind: .image, byteCount: 10)
        let unique = ChatAttachment(name: "remove", mimeType: "text/plain", kind: .text, byteCount: 20)
        let first = Conversation(profileID: supplier, messages: [ChatMessage(role: .user, attachments: [shared, unique])])
        let second = Conversation(profileID: supplier, messages: [ChatMessage(role: .user, attachments: [unique])])
        let keep = Conversation(profileID: supplier, messages: [ChatMessage(role: .user, attachments: [shared])])
        var history = [first, second, keep]
        let files = ConversationBatchActions.remove([first.id, second.id], from: &history)
        XCTAssertEqual(files, [unique])
        XCTAssertEqual(history, [keep])
        XCTAssertEqual(ConversationBatchActions.remove([keep.id], from: &history), [shared])
        XCTAssertTrue(history.isEmpty)
    }

    func testPinAndUnpinSelectionPreserveDatesMessagesAndUnselectedPin() throws {
        let supplier = UUID()
        let first = Conversation(title: "first", profileID: supplier, updatedAt: Date(timeIntervalSince1970: 100))
        let second = Conversation(title: "second", profileID: supplier, updatedAt: Date(timeIntervalSince1970: 200), isPinned: true)
        var history = [first, second]
        ConversationBatchActions.setPinned(true, ids: [first.id, UUID()], in: &history)
        XCTAssertTrue(history.allSatisfy(\.isPinned))
        XCTAssertEqual(history[0].updatedAt, first.updatedAt)
        ConversationBatchActions.setPinned(false, ids: [first.id], in: &history)
        XCTAssertEqual(history, [first, second])
        XCTAssertEqual(try JSONDecoder().decode([Conversation].self, from: JSONEncoder().encode(history)), history)
    }

    func testEmptyOrStaleSelectionDoesNotAlterHistoryOrReturnAttachments() {
        let file = ChatAttachment(name: "keep", mimeType: "text/plain", kind: .text, byteCount: 1)
        let original = [Conversation(profileID: UUID(), messages: [ChatMessage(role: .user, attachments: [file])])]
        var history = original
        XCTAssertTrue(ConversationBatchActions.remove([], from: &history).isEmpty)
        XCTAssertTrue(ConversationBatchActions.remove([UUID()], from: &history).isEmpty)
        ConversationBatchActions.setPinned(true, ids: [], in: &history)
        ConversationBatchActions.setPinned(true, ids: [UUID()], in: &history)
        XCTAssertEqual(history, original)
    }
}
