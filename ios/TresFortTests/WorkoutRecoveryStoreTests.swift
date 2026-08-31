import Foundation
import XCTest
@testable import TresFort

@MainActor
final class WorkoutRecoveryStoreTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "WorkoutRecoveryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func state(
        planName: String = "Cached Plan",
        serverTime: Int = 2_000_000_000_000
    ) throws -> StateResponse {
        let object: [String: Any] = [
            "plan": [
                "id": "plan-a",
                "name": planName,
                "version": 7,
                "days": [[
                    "id": "day-a",
                    "name": "Day A",
                    "day_label": "A",
                    "order_index": 0,
                    "exercises": [[
                        "id": "slot-a",
                        "exercise_id": "exercise-a",
                        "exercise_name": "Squat",
                        "exercise_unit": "lb",
                        "order_index": 0,
                        "target_sets": 3,
                        "target_reps": 5,
                        "target_reps_max": NSNull(),
                        "target_rpe": NSNull(),
                        "rest_seconds": 90,
                        "target_weight": 100,
                        "cues": NSNull(),
                        "exercise_modality": "barbell",
                        "exercise_laterality": "bilateral",
                        "exercise_load_mode": "total",
                        "exercise_demo_slug": NSNull(),
                        "target_duration_s": NSNull(),
                        "is_warmup": 0,
                    ]],
                ]],
                "meta": NSNull(),
            ],
            "plan_version": 7,
            "sessions": [[
                "id": "session-a",
                "date": "2033-05-18",
                "status": "in_progress",
                "day_template_id": "day-a",
                "updated_at": 2_000_000_000_001,
                "attempt": 7,
            ]],
            "sets": [],
            "external_events": [],
            "external_activities": [],
            "activities": [],
            "server_time": serverTime,
        ]
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(StateResponse.self, from: data)
    }

    func testCheckpointRoundTripsWithinOneAccount() {
        let defaults = defaults()
        let checkpoint = WorkoutRunnerCheckpoint(
            date: "2033-05-18",
            sessionID: "session-a",
            selectedDayID: "day-a",
            currentSlotID: "slot-b",
            skippedSlotIDs: ["slot-a"],
            workoutStartedAtMS: 2_000_000_000_000,
            finished: false,
            sessionAttempt: 7,
            restartDiscardedAttempt: 6)

        WorkoutRunnerCheckpointStore.save(
            checkpoint, userID: "user-a", defaults: defaults)

        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults),
            checkpoint)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.sessionAttempt,
            7)
        XCTAssertEqual(
            WorkoutRunnerCheckpointStore.load(
                userID: "user-a", defaults: defaults)?.restartDiscardedAttempt,
            6)
        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-b", defaults: defaults))
    }

    func testCheckpointAndSnapshotCorruptionFailClosed() {
        let defaults = defaults()
        defaults.set(
            Data("not-json".utf8),
            forKey: WorkoutRunnerCheckpointStore.scopedKey(userID: "user-a"))
        defaults.set(
            Data("not-json".utf8),
            forKey: StateSnapshotStore.scopedKey(userID: "user-a"))

        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testStateSnapshotRoundTripsFullStateAndIsAccountScoped() throws {
        let defaults = defaults()
        StateSnapshotStore.save(
            try state(), userID: "user-a", defaults: defaults)

        let loaded = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(loaded.state.plan?.name, "Cached Plan")
        XCTAssertEqual(loaded.state.plan?.days.first?.exercises.first?.id, "slot-a")
        XCTAssertEqual(loaded.state.sessions.first?.status, "in_progress")
        XCTAssertEqual(loaded.state.sessions.first?.attempt, 7)
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-b", defaults: defaults))
    }

    func testLaterReservationRejectsEarlierCommitRegardlessOfServerTime() throws {
        let defaults = defaults()
        let older = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(
            userID: "user-a", defaults: defaults))
        let newer = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(
            userID: "user-a", defaults: defaults))

        XCTAssertNil(StateSnapshotStore.commitFullState(
            try state(planName: "Stale", serverTime: Int.max),
            ticket: older,
            defaults: defaults))
        XCTAssertNotNil(StateSnapshotStore.commitFullState(
            try state(planName: "Current", serverTime: 1),
            ticket: newer,
            defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.plan?.name,
            "Current")
    }

    func testAcknowledgementMergeInvalidatesOutstandingFullStateTicket() throws {
        let defaults = defaults()
        StateSnapshotStore.save(
            try state(planName: "Baseline"),
            userID: "user-a",
            defaults: defaults)
        let ticket = try XCTUnwrap(
            StateSnapshotStore.reserveFullStateRequest(
                userID: "user-a", defaults: defaults))
        let acknowledged = try state(planName: "Acknowledged")

        XCTAssertNotNil(StateSnapshotStore.mergeAcknowledgement(
            userID: "user-a",
            fallback: try state(planName: "Fallback"),
            defaults: defaults
        ) { _ in acknowledged })
        XCTAssertNil(StateSnapshotStore.commitFullState(
            try state(planName: "Late response"),
            ticket: ticket,
            defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.plan?.name,
            "Acknowledged")
    }

    func testAcknowledgementMergeUsesNewestSnapshotInsteadOfStaleFallback() throws {
        let defaults = defaults()
        StateSnapshotStore.save(
            try state(planName: "Newest"),
            userID: "user-a",
            defaults: defaults)

        let merged = StateSnapshotStore.mergeAcknowledgement(
            userID: "user-a",
            fallback: try state(planName: "Stale fallback"),
            defaults: defaults
        ) { $0 }

        XCTAssertEqual(merged?.state.plan?.name, "Newest")
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.state.plan?.name,
            "Newest")
    }

    func testInvalidationRejectsOutstandingPullAndDelayedACKFallback() throws {
        let defaults = defaults()
        StateSnapshotStore.save(
            try state(planName: "Before delete"),
            userID: "user-a",
            defaults: defaults)
        let ticket = try XCTUnwrap(
            StateSnapshotStore.reserveFullStateRequest(
                userID: "user-a", defaults: defaults))

        XCTAssertTrue(StateSnapshotStore.invalidate(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(StateSnapshotStore.commitFullState(
            try state(planName: "Late full response"),
            ticket: ticket,
            defaults: defaults))
        XCTAssertNil(StateSnapshotStore.mergeAcknowledgement(
            userID: "user-a",
            fallback: try state(planName: "Late ACK fallback"),
            defaults: defaults
        ) { $0 })
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
    }

    func testExerciseCatalogSnapshotRoundTripsAndIsAccountScoped() throws {
        let defaults = defaults()
        let row = ExerciseCatalog(
            id: "exercise-a",
            name: "Split Squat",
            primary_muscle: "legs",
            modality: "dumbbell",
            unit: "lb",
            laterality: "unilateral",
            load_mode: "per_hand",
            demo_slug: "split-squat")

        ExerciseCatalogSnapshotStore.save(
            [row], userID: "user-a", defaults: defaults)

        let loaded = try XCTUnwrap(ExerciseCatalogSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.first)
        XCTAssertEqual(loaded.name, "Split Squat")
        XCTAssertEqual(loaded.laterality, "unilateral")
        XCTAssertEqual(loaded.load_mode, "per_hand")
        XCTAssertNil(ExerciseCatalogSnapshotStore.load(
            userID: "user-b", defaults: defaults))
    }

    func testAccountLocalStateClearRemovesRecoveryDataForOnlyThatAccount() throws {
        let defaults = defaults()
        let checkpoint = WorkoutRunnerCheckpoint(
            date: "2033-05-18",
            sessionID: nil,
            selectedDayID: "day-a",
            currentSlotID: "slot-a",
            skippedSlotIDs: [],
            workoutStartedAtMS: 2_000_000_000_000,
            finished: false)
        for userID in ["user-a", "user-b"] {
            WorkoutRunnerCheckpointStore.save(
                checkpoint, userID: userID, defaults: defaults)
            StateSnapshotStore.save(
                try state(planName: userID),
                userID: userID,
                defaults: defaults)
            ExerciseCatalogSnapshotStore.save(
                [ExerciseCatalog(
                    id: "exercise-\(userID)",
                    name: userID,
                    primary_muscle: "legs",
                    modality: "barbell",
                    unit: "lb",
                    laterality: "bilateral",
                    load_mode: "total",
                    demo_slug: nil)],
                userID: userID,
                defaults: defaults)
        }

        AccountLocalState.clear(userID: "user-a", defaults: defaults)

        XCTAssertNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNil(ExerciseCatalogSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertNotNil(WorkoutRunnerCheckpointStore.load(
            userID: "user-b", defaults: defaults))
        XCTAssertEqual(StateSnapshotStore.load(
            userID: "user-b", defaults: defaults)?.state.plan?.name, "user-b")
        XCTAssertEqual(ExerciseCatalogSnapshotStore.load(
            userID: "user-b", defaults: defaults)?.first?.name, "user-b")
    }
}
