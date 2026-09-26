import XCTest
@testable import TresFort

final class RunnerRecoveryTests: XCTestCase {
    private let today = "2026-09-14"
    private func checkpoint(attempt: Int? = 2) -> WorkoutRunnerCheckpoint {
        .init(date: today, sessionID: "session", selectedDayID: "workout",
              currentSlotID: "slot", skippedSlotIDs: [], workoutStartedAtMS: 1,
              finished: false, sessionAttempt: attempt)
    }
    private func session(status: String = "in_progress", attempt: Int? = 2) -> SessionRow {
        .init(id: "session", date: today, status: status, workout_id: "workout", attempt: attempt)
    }

    func testOfflineResumeRequiresTheSameKnownAttempt() {
        XCTAssertTrue(RunnerRecovery.canResumeOffline(checkpoint(), session: session()))
        XCTAssertFalse(RunnerRecovery.canResumeOffline(checkpoint(), session: session(attempt: 3)))
        XCTAssertFalse(RunnerRecovery.canResumeOffline(checkpoint(attempt: nil), session: session(attempt: nil)))
        XCTAssertFalse(RunnerRecovery.canResumeOffline(checkpoint(), session: nil))
        for status in ["completed", "skipped", "discarded"] {
            XCTAssertFalse(RunnerRecovery.canResumeOffline(checkpoint(), session: session(status: status)))
        }
    }

    func testCachedConflictWaitsAndLiveConflictRetiresTheRunner() {
        for offline in [true, false] {
            let result = RunnerRecovery.decision(checkpoint(), session: session(attempt: 3),
                today: today, mounted: false, hasTerminalIntent: false,
                hasPendingFirstSet: true, offline: offline)
            switch result {
            case .waitingForValidation: XCTAssertTrue(offline)
            case .discard: XCTAssertFalse(offline)
            default: XCTFail("A competing attempt must never be resumed")
            }
        }
        let result = RunnerRecovery.decision(checkpoint(), session: session(status: "completed"),
            today: today, mounted: true, hasTerminalIntent: false,
            hasPendingFirstSet: true, offline: false)
        guard case .discard = result else { return XCTFail("Remote completion must stop mounted work") }
    }

    func testUnboundOfflineWorkAndPendingTerminalIntentHaveDistinctOutcomes() {
        let unbound = WorkoutRunnerCheckpoint(date: today, sessionID: nil, selectedDayID: "workout",
            currentSlotID: "slot", skippedSlotIDs: [], workoutStartedAtMS: 1, finished: false)
        let result = RunnerRecovery.decision(unbound, session: nil, today: today,
            mounted: false, hasTerminalIntent: false, hasPendingFirstSet: true, offline: true)
        guard case .resume = result else { return XCTFail("Unsent offline work should resume") }
        let blocked = RunnerRecovery.decision(unbound, session: nil, today: today,
            mounted: false, hasTerminalIntent: true, hasPendingFirstSet: true, offline: true)
        guard case .waitingForValidation = blocked else { return XCTFail("Finish/discard keeps precedence") }
    }
}
