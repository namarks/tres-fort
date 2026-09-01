import Foundation
import XCTest
@testable import TresFort

final class WorkoutTerminalOutboxTests: XCTestCase {
    private let date = "2033-05-18"

    private func defaults() -> UserDefaults {
        let name = "WorkoutTerminalOutboxTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func intent(
        id: String,
        action: WorkoutTerminalAction = .finish,
        date: String? = nil,
        dayTemplateID: String? = "day-a",
        resolvedSessionID: String? = nil,
        deliveryState: WorkoutTerminalDeliveryState = .queued,
        failedHTTPStatus: Int? = nil,
        expectedAttempt: Int? = nil,
        restartDiscardedAttempt: Int? = nil
    ) -> WorkoutTerminalIntent {
        WorkoutTerminalIntent(
            id: id,
            action: action,
            date: date ?? self.date,
            dayTemplateID: dayTemplateID,
            resolvedSessionID: resolvedSessionID,
            deliveryState: deliveryState,
            failedHTTPStatus: failedHTTPStatus,
            expectedAttempt: expectedAttempt,
            restartDiscardedAttempt: restartDiscardedAttempt)
    }

    func testPersistsFinishIntentAcrossRelaunchAndGranularUpdate() {
        let defaults = defaults()
        let queued = intent(
            id: "finish-a",
            expectedAttempt: 7,
            restartDiscardedAttempt: 6)
        WorkoutTerminalOutboxStore.enqueue(
            queued, userID: "user-a", defaults: defaults)

        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).intent(for: date),
            queued)

        let failed = intent(
            id: "finish-a",
            resolvedSessionID: "session-a",
            deliveryState: .failed,
            failedHTTPStatus: 422)
        WorkoutTerminalOutboxStore.replace(
            failed, userID: "user-a", defaults: defaults)

        let relaunched = WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults)
        let persisted = relaunched.intent(for: date)
        XCTAssertEqual(persisted?.id, failed.id)
        XCTAssertEqual(persisted?.resolvedSessionID, failed.resolvedSessionID)
        XCTAssertEqual(persisted?.deliveryState, failed.deliveryState)
        XCTAssertEqual(persisted?.failedHTTPStatus, failed.failedHTTPStatus)
        XCTAssertEqual(persisted?.expectedAttempt, 7)
        XCTAssertEqual(persisted?.restartDiscardedAttempt, 6)
        XCTAssertEqual(relaunched.count, 1)
    }

    func testDiscardReplacesFinishAndCanNeverBeReplacedByFinish() {
        var outbox = WorkoutTerminalOutbox()
        let finish = intent(id: "finish-a")
        let discard = intent(id: "discard-a", action: .discard)

        outbox.enqueue(finish)
        outbox.enqueue(discard)
        XCTAssertEqual(outbox.intent(for: date), discard)

        outbox.enqueue(intent(id: "finish-b"))
        XCTAssertEqual(outbox.intent(for: date), discard)

        // A second discard tap also retains the current immutable barrier.
        outbox.enqueue(intent(id: "discard-b", action: .discard))
        XCTAssertEqual(outbox.intent(for: date), discard)
    }

    func testLateFinishCallbacksCannotOverwriteOrRemoveNewerDiscard() {
        let defaults = defaults()
        let finish = intent(id: "finish-a")
        let discard = intent(id: "discard-a", action: .discard)
        WorkoutTerminalOutboxStore.enqueue(
            finish, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.enqueue(
            discard, userID: "user-a", defaults: defaults)

        let lateFailure = intent(
            id: "finish-a",
            resolvedSessionID: "session-a",
            deliveryState: .failed,
            failedHTTPStatus: 409)
        WorkoutTerminalOutboxStore.replace(
            lateFailure, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.remove(
            id: finish.id, userID: "user-a", defaults: defaults)

        XCTAssertEqual(
            WorkoutTerminalOutboxStore.load(
                userID: "user-a", defaults: defaults).intent(for: date),
            discard)
    }

    func testLateReplaceCannotRecreateExplicitlyClearedBarrier() {
        let defaults = defaults()
        let acknowledged = intent(
            id: "discard-a",
            action: .discard,
            resolvedSessionID: "session-a",
            deliveryState: .acknowledged)
        WorkoutTerminalOutboxStore.enqueue(
            acknowledged, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
            date: date, userID: "user-a", defaults: defaults)

        WorkoutTerminalOutboxStore.replace(
            acknowledged, userID: "user-a", defaults: defaults)

        XCTAssertTrue(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).isEmpty)
    }

    func testAcknowledgedDiscardPersistsUntilExplicitClear() {
        let defaults = defaults()
        let queued = intent(id: "discard-a", action: .discard)
        WorkoutTerminalOutboxStore.enqueue(
            queued, userID: "user-a", defaults: defaults)

        // Neither generic removal nor premature explicit clearing can erase it.
        WorkoutTerminalOutboxStore.remove(
            id: queued.id, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
            date: date, userID: "user-a", defaults: defaults)
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).intent(for: date), queued)

        let acknowledged = intent(
            id: "discard-a",
            action: .discard,
            resolvedSessionID: "session-a",
            deliveryState: .acknowledged)
        WorkoutTerminalOutboxStore.replace(
            acknowledged, userID: "user-a", defaults: defaults)

        let relaunched = WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults)
        XCTAssertEqual(relaunched.intent(for: date), acknowledged)

        WorkoutTerminalOutboxStore.remove(
            id: acknowledged.id, userID: "user-a", defaults: defaults)
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).intent(for: date), acknowledged)

        WorkoutTerminalOutboxStore.clearAcknowledgedDiscard(
            date: date, userID: "user-a", defaults: defaults)
        XCTAssertTrue(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).isEmpty)
    }

    func testAcknowledgementAndResolvedSessionCannotRegress() {
        var outbox = WorkoutTerminalOutbox()
        let acknowledged = intent(
            id: "discard-a",
            action: .discard,
            resolvedSessionID: "session-a",
            deliveryState: .acknowledged)
        outbox.enqueue(acknowledged)

        outbox.replace(intent(
            id: "discard-a",
            action: .discard,
            deliveryState: .failed,
            failedHTTPStatus: 503))
        XCTAssertEqual(outbox.intent(for: date), acknowledged)

        var queued = WorkoutTerminalOutbox()
        queued.enqueue(intent(
            id: "finish-a",
            resolvedSessionID: "session-a"))
        queued.replace(intent(id: "finish-a", deliveryState: .failed))
        XCTAssertEqual(
            queued.intent(for: date)?.resolvedSessionID,
            "session-a")
    }

    func testAcknowledgedDiscardCanOnlyRequeueThroughExplicitRevivalPath() {
        let defaults = defaults()
        let acknowledged = intent(
            id: "discard-a",
            action: .discard,
            resolvedSessionID: "session-old",
            deliveryState: .acknowledged)
        WorkoutTerminalOutboxStore.enqueue(
            acknowledged, userID: "user-a", defaults: defaults)

        // Generic replacement remains monotonic.
        WorkoutTerminalOutboxStore.replace(
            intent(
                id: "discard-a",
                action: .discard,
                resolvedSessionID: "session-new"),
            userID: "user-a",
            defaults: defaults)
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).intent(for: date), acknowledged)

        WorkoutTerminalOutboxStore.requeueAcknowledgedDiscard(
            date: date,
            resolvedSessionID: "session-new",
            expectedAttempt: 0,
            userID: "user-a",
            defaults: defaults)

        let requeued = WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).intent(for: date)
        XCTAssertEqual(requeued?.id, acknowledged.id)
        XCTAssertEqual(requeued?.action, .discard)
        XCTAssertEqual(requeued?.resolvedSessionID, "session-new")
        XCTAssertEqual(requeued?.deliveryState, .queued)
        XCTAssertNil(requeued?.failedHTTPStatus)
    }

    func testAccountsAreIsolated() {
        let defaults = defaults()
        let first = intent(id: "finish-a")
        let second = intent(
            id: "discard-b", action: .discard, date: "2033-05-19")
        WorkoutTerminalOutboxStore.enqueue(
            first, userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.enqueue(
            second, userID: "user-b", defaults: defaults)

        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).intents, [first])
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-b", defaults: defaults).intents, [second])
        XCTAssertTrue(WorkoutTerminalOutboxStore.load(
            userID: nil, defaults: defaults).isEmpty)
    }

    func testClearRemovesOnlySelectedAccount() {
        let defaults = defaults()
        WorkoutTerminalOutboxStore.enqueue(
            intent(id: "finish-a"), userID: "user-a", defaults: defaults)
        WorkoutTerminalOutboxStore.enqueue(
            intent(id: "finish-b"), userID: "user-b", defaults: defaults)

        WorkoutTerminalOutboxStore.clear(userID: "user-a", defaults: defaults)

        XCTAssertTrue(WorkoutTerminalOutboxStore.load(
            userID: "user-a", defaults: defaults).isEmpty)
        XCTAssertEqual(WorkoutTerminalOutboxStore.load(
            userID: "user-b", defaults: defaults).count, 1)
    }
}
