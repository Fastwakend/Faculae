import XCTest
@testable import SeekCore

final class ReplyExecutionTests: XCTestCase {
    func testSubmittedRequestIsNotAnExecutionGrant() {
        var state = ReplyExecutionLedger()
        let reply = UUID(), request = UUID()
        state.begin(reply); XCTAssertTrue(state.prepare(reply, requestID: request))
        XCTAssertEqual(state.unprotectedReplies(inBackground: true, backgroundEnabled: true,
                                               sharedExecutionAvailable: false), [reply])
        XCTAssertTrue(state.accept(reply, requestID: request))
        XCTAssertTrue(state.unprotectedReplies(inBackground: true, backgroundEnabled: true,
                                              sharedExecutionAvailable: false).isEmpty)
    }

    func testOneReplyFinishingDoesNotStopOtherRepliesExperimentsOrGrant() {
        var state = ReplyExecutionLedger()
        let first = UUID(), second = UUID(), request = UUID()
        state.begin(first); state.begin(second)
        state.prepare(second, requestID: request); state.accept(second, requestID: request)
        state.finish(first)
        XCTAssertEqual(state.replies, [second]); XCTAssertEqual(state.running, [second])
        XCTAssertTrue(state.needsExperiments(backgroundEnabled: true, experimentEnabled: true))
        state.finish(second)
        XCTAssertFalse(state.needsExperiments(backgroundEnabled: true, experimentEnabled: true))
        XCTAssertTrue(state.requests.isEmpty); XCTAssertTrue(state.running.isEmpty)
    }

    func testCompletedOrCancelledReplyRejectsLateCallbacks() {
        var state = ReplyExecutionLedger()
        let reply = UUID(), request = UUID()
        state.begin(reply); state.prepare(reply, requestID: request); state.finish(reply)
        XCTAssertFalse(state.accept(reply, requestID: request))
        XCTAssertFalse(state.expire(reply, requestID: request))
        state.reject(reply, requestID: request)
        XCTAssertTrue(state.replies.isEmpty); XCTAssertTrue(state.running.isEmpty)
    }

    func testOldAttemptCannotExpireOrRejectNewAttempt() {
        var state = ReplyExecutionLedger()
        let reply = UUID(), old = UUID(), new = UUID()
        state.begin(reply); state.prepare(reply, requestID: old)
        state.releaseContinuedRequests(); state.prepare(reply, requestID: new)
        XCTAssertFalse(state.accept(reply, requestID: old))
        XCTAssertTrue(state.accept(reply, requestID: new))
        XCTAssertFalse(state.expire(reply, requestID: old)); state.reject(reply, requestID: old)
        XCTAssertTrue(state.matches(reply, requestID: new)); XCTAssertEqual(state.running, [reply])
    }

    func testExpirationTargetsOnlyItsOwnReply() {
        var state = ReplyExecutionLedger()
        let first = UUID(), second = UUID(), a = UUID(), b = UUID()
        for (reply, request) in [(first, a), (second, b)] {
            state.begin(reply); state.prepare(reply, requestID: request); state.accept(reply, requestID: request)
        }
        XCTAssertTrue(state.expire(first, requestID: a))
        XCTAssertFalse(state.expire(first, requestID: a))
        state.finish(first)
        XCTAssertEqual(state.running, [second]); XCTAssertTrue(state.matches(second, requestID: b))
    }

    func testSharedTimeExpiryStopsOnlyRepliesWithoutOtherExecution() {
        var state = ReplyExecutionLedger()
        let first = UUID(), second = UUID(), request = UUID()
        state.begin(first); state.begin(second); state.prepare(first, requestID: request)
        state.accept(first, requestID: request)
        XCTAssertTrue(state.unprotectedReplies(inBackground: true, backgroundEnabled: true,
                                              sharedExecutionAvailable: true).isEmpty)
        XCTAssertEqual(state.unprotectedReplies(inBackground: true, backgroundEnabled: true,
                                               sharedExecutionAvailable: false), [second])
        XCTAssertTrue(state.unprotectedReplies(inBackground: false, backgroundEnabled: true,
                                              sharedExecutionAvailable: false).isEmpty)
    }

    func testMasterOffOverridesAllExecutionAndExperimentSettings() {
        var state = ReplyExecutionLedger()
        let reply = UUID(), request = UUID()
        state.begin(reply); state.prepare(reply, requestID: request); state.accept(reply, requestID: request)
        XCTAssertEqual(state.unprotectedReplies(inBackground: true, backgroundEnabled: false,
                                               sharedExecutionAvailable: true), [reply])
        XCTAssertFalse(state.needsExperiments(backgroundEnabled: false, experimentEnabled: true))
        XCTAssertFalse(state.needsExperiments(backgroundEnabled: true, experimentEnabled: false))
        state.releaseContinuedRequests()
        XCTAssertEqual(state.replies, [reply]); XCTAssertTrue(state.requests.isEmpty)
    }

    func testDuplicateBeginAndRequestCannotOverwriteRunningAttempt() {
        var state = ReplyExecutionLedger()
        let reply = UUID(), first = UUID(), second = UUID()
        XCTAssertTrue(state.begin(reply)); XCTAssertFalse(state.begin(reply))
        XCTAssertTrue(state.prepare(reply, requestID: first))
        XCTAssertFalse(state.prepare(reply, requestID: second))
        XCTAssertTrue(state.accept(reply, requestID: first)); XCTAssertFalse(state.accept(reply, requestID: first))
        state.reject(reply, requestID: first)
        XCTAssertTrue(state.matches(reply, requestID: first)); XCTAssertEqual(state.running, [reply])
    }
}
