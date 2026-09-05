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
        serverTime: Int = 2_000_000_000_000,
        externalSyncCursorsVersion: Int? = nil
    ) throws -> StateResponse {
        var object: [String: Any] = [
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
        if let externalSyncCursorsVersion {
            object["external_sync_cursors_version"] =
                externalSyncCursorsVersion
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(StateResponse.self, from: data)
    }

    private func set(
        id: String,
        deletedAt: Int? = nil,
        loggedAt: Int = 1_000,
        updatedAt: Int = 2_000_000_000_001
    ) -> SetLog {
        SetLog(
            id: id,
            session_id: "session-a",
            exercise_id: "exercise-a",
            template_exercise_id: "slot-a",
            set_index: 0,
            weight: 100,
            reps: 5,
            rpe: nil,
            is_warmup: 0,
            logged_at: loggedAt,
            duration_s: nil,
            is_timed: 0,
            deleted_at: deletedAt,
            updated_at: updatedAt)
    }

    private func event(
        id: String,
        deletedAt: Int? = nil,
        syncedAt: Int? = 1_000
    ) -> ExternalEvent {
        ExternalEvent(
            id: id,
            source: "intervals",
            external_id: id,
            date: "2033-05-18",
            kind: "ride",
            title: "Ride",
            description: nil,
            planned_duration_sec: 3_600,
            training_load: nil,
            intensity: nil,
            synced_at: syncedAt,
            deleted_at: deletedAt)
    }

    private func externalActivity(
        id: String,
        deletedAt: Int? = nil,
        syncedAt: Int? = 1_000
    ) -> ExternalActivity {
        ExternalActivity(
            id: id,
            source: "intervals",
            external_id: id,
            date: "2033-05-18",
            kind: "run",
            name: "Run",
            moving_time_sec: 1_800,
            elapsed_time_sec: nil,
            distance_m: nil,
            average_watts: nil,
            weighted_avg_watts: nil,
            average_hr: nil,
            max_hr: nil,
            training_load: nil,
            intensity: nil,
            calories: nil,
            elevation_gain_m: nil,
            synced_at: syncedAt,
            deleted_at: deletedAt)
    }

    private func activity(
        id: String,
        loggedAt: Int,
        deletedAt: Int? = nil
    ) -> ActivityRow {
        var row = ActivityRow(
            id: id,
            user_id: "user-a",
            date: "2020-01-01",
            type: "walk",
            title: "Backdated walk",
            duration_minutes: 30,
            notes: nil,
            logged_at: loggedAt,
            source: "manual",
            deleted_at: deletedAt)
        row.updated_at = deletedAt ?? 2_000_000_000_001
        return row
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

    func testP1PersistsActiveOverlappedCursorsAndLeavesP2CursorsAtZero() throws {
        let defaults = defaults()
        let ticket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(ticket.watermarks, .fullReload)

        let serverTime = 2_000_000_123_456
        let committed = try XCTUnwrap(StateSnapshotStore.commitStateResponse(
            try state(serverTime: serverTime),
            ticket: ticket,
            defaults: defaults))
        let expected = StateSyncWatermarks(
            planVersion: 7,
            setsSince: serverTime - 60_000,
            eventsSince: 0,
            activitiesSince: 0,
            logSince: serverTime - 60_000)
        XCTAssertEqual(committed.watermarks, expected)

        let next = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(next.watermarks, expected)
    }

    func testP2ExternalCursorCapabilityUsesOverlapAndComparableRows() throws {
        let serverTime = 2_000_000_123_456
        let baseline = try state(serverTime: serverTime)
        let capable = StateResponse(
            plan: baseline.plan,
            plan_version: baseline.plan_version,
            sessions: baseline.sessions,
            sets: baseline.sets,
            external_events: [event(id: "event-a")],
            external_activities: [externalActivity(id: "activity-a")],
            activities: baseline.activities,
            server_time: serverTime,
            externalSyncCursorsVersion: 2)
        let expectedCursor = serverTime
            - StateSyncWatermarks.overlapMilliseconds

        XCTAssertEqual(capable.externalSyncCursorsVersion, 2)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: capable).eventsSince,
            expectedCursor)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: capable).activitiesSince,
            expectedCursor)

        let incomparableEvent = StateResponse(
            plan: baseline.plan,
            plan_version: baseline.plan_version,
            sessions: baseline.sessions,
            sets: baseline.sets,
            external_events: [event(id: "event-a", syncedAt: nil)],
            external_activities: [externalActivity(id: "activity-a")],
            activities: baseline.activities,
            server_time: serverTime,
            externalSyncCursorsVersion: 2)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: incomparableEvent).eventsSince,
            0)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: incomparableEvent)
                .activitiesSince,
            expectedCursor)

        let incomparableActivity = StateResponse(
            plan: baseline.plan,
            plan_version: baseline.plan_version,
            sessions: baseline.sessions,
            sets: baseline.sets,
            external_events: [event(id: "event-a")],
            external_activities: [externalActivity(
                id: "activity-a", syncedAt: nil)],
            activities: baseline.activities,
            server_time: serverTime,
            externalSyncCursorsVersion: 2)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: incomparableActivity).eventsSince,
            expectedCursor)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: incomparableActivity)
                .activitiesSince,
            0)
    }

    func testP2CapabilityRequiresVersionTwoAndStrictExternalArrays() throws {
        let serverTime = 2_000_000_123_456
        for version in [nil, 1] as [Int?] {
            let response = try state(
                serverTime: serverTime,
                externalSyncCursorsVersion: version)
            let watermarks = StateSyncWatermarks.next(after: response)
            XCTAssertEqual(watermarks.eventsSince, 0)
            XCTAssertEqual(watermarks.activitiesSince, 0)
        }

        let capable = try state(
            serverTime: serverTime,
            externalSyncCursorsVersion: 2)
        XCTAssertEqual(capable.externalSyncCursorsVersion, 2)
        let persisted = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONEncoder().encode(capable))
        XCTAssertEqual(persisted.externalSyncCursorsVersion, 2)

        let encoded = try JSONEncoder().encode(capable)
        let baseObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["external_events", "external_activities"] {
            var missing = baseObject
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try JSONDecoder().decode(
                StateResponse.self,
                from: JSONSerialization.data(withJSONObject: missing)))

            var null = baseObject
            null[key] = NSNull()
            XCTAssertThrowsError(try JSONDecoder().decode(
                StateResponse.self,
                from: JSONSerialization.data(withJSONObject: null)))

            var malformed = baseObject
            malformed[key] = [["id": 123]]
            XCTAssertThrowsError(try JSONDecoder().decode(
                StateResponse.self,
                from: JSONSerialization.data(withJSONObject: malformed)))
        }

        var malformedCapability = baseObject
        malformedCapability["external_sync_cursors_version"] = "2"
        XCTAssertThrowsError(try JSONDecoder().decode(
            StateResponse.self,
            from: JSONSerialization.data(withJSONObject: malformedCapability)))
    }

    func testP2RollbackResetsExternalCursorsThenLegacyFullReplaces() throws {
        let defaults = defaults()
        let initialTime = 2_000_000_000_000
        let baseline = try state(serverTime: initialTime)
        let initial = StateResponse(
            plan: baseline.plan,
            plan_version: baseline.plan_version,
            sessions: baseline.sessions,
            sets: baseline.sets,
            external_events: [event(id: "event-a")],
            external_activities: [externalActivity(id: "activity-a")],
            activities: baseline.activities,
            server_time: initialTime,
            externalSyncCursorsVersion: 2)
        StateSnapshotStore.save(
            initial, userID: "user-a", defaults: defaults)

        let rollbackTicket = try XCTUnwrap(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults))
        XCTAssertGreaterThan(rollbackTicket.watermarks.eventsSince, 0)
        XCTAssertGreaterThan(rollbackTicket.watermarks.activitiesSince, 0)
        let rollback = StateResponse(
            plan: nil,
            plan_version: baseline.plan_version,
            sessions: [],
            sets: [],
            external_events: [],
            external_activities: [],
            activities: [],
            server_time: initialTime + 100_000)
        let afterRollback = try XCTUnwrap(
            StateSnapshotStore.commitStateResponse(
                rollback,
                ticket: rollbackTicket,
                defaults: defaults))
        XCTAssertEqual(afterRollback.state.external_events.map(\.id), ["event-a"])
        XCTAssertEqual(
            afterRollback.state.external_activities.map(\.id), ["activity-a"])
        XCTAssertEqual(afterRollback.watermarks?.eventsSince, 0)
        XCTAssertEqual(afterRollback.watermarks?.activitiesSince, 0)

        let legacyFullTicket = try XCTUnwrap(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults))
        XCTAssertEqual(legacyFullTicket.watermarks.eventsSince, 0)
        XCTAssertEqual(legacyFullTicket.watermarks.activitiesSince, 0)
        let legacyFull = StateResponse(
            plan: nil,
            plan_version: baseline.plan_version,
            sessions: [],
            sets: [],
            external_events: [event(id: "event-b")],
            external_activities: [externalActivity(id: "activity-b")],
            activities: [],
            server_time: initialTime + 200_000)
        let replaced = try XCTUnwrap(
            StateSnapshotStore.commitStateResponse(
                legacyFull,
                ticket: legacyFullTicket,
                defaults: defaults))
        XCTAssertEqual(replaced.state.external_events.map(\.id), ["event-b"])
        XCTAssertEqual(
            replaced.state.external_activities.map(\.id), ["activity-b"])
        XCTAssertEqual(replaced.watermarks?.eventsSince, 0)
        XCTAssertEqual(replaced.watermarks?.activitiesSince, 0)
    }

    func testP2ExternalTombstonesMergeIdempotently() throws {
        let defaults = defaults()
        let initialTime = 2_000_000_000_000
        let baseline = try state(serverTime: initialTime)
        StateSnapshotStore.save(
            StateResponse(
                plan: baseline.plan,
                plan_version: baseline.plan_version,
                sessions: baseline.sessions,
                sets: baseline.sets,
                external_events: [event(id: "event-a")],
                external_activities: [externalActivity(id: "activity-a")],
                activities: baseline.activities,
                server_time: initialTime,
                externalSyncCursorsVersion: 2),
            userID: "user-a",
            defaults: defaults)

        let tombstoneTime = initialTime + 10_000
        let tombstones = StateResponse(
            plan: nil,
            plan_version: baseline.plan_version,
            sessions: [],
            sets: [],
            external_events: [event(
                id: "event-a",
                deletedAt: tombstoneTime,
                syncedAt: tombstoneTime)],
            external_activities: [externalActivity(
                id: "activity-a",
                deletedAt: tombstoneTime,
                syncedAt: tombstoneTime)],
            activities: [],
            server_time: initialTime + 100_000,
            externalSyncCursorsVersion: 2)
        for _ in 0..<2 {
            let ticket = try XCTUnwrap(
                StateSnapshotStore.reserveStateRequest(
                    userID: "user-a", defaults: defaults))
            XCTAssertGreaterThan(ticket.watermarks.eventsSince, 0)
            XCTAssertGreaterThan(ticket.watermarks.activitiesSince, 0)
            XCTAssertNotNil(StateSnapshotStore.commitStateResponse(
                tombstones, ticket: ticket, defaults: defaults))
        }

        let final = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertTrue(final.state.external_events.isEmpty)
        XCTAssertTrue(final.state.external_activities.isEmpty)
        XCTAssertEqual(
            final.watermarks?.eventsSince,
            tombstones.server_time - StateSyncWatermarks.overlapMilliseconds)
        XCTAssertEqual(
            final.watermarks?.activitiesSince,
            tombstones.server_time - StateSyncWatermarks.overlapMilliseconds)
    }

    func testMalformedP2ExternalPayloadDoesNotAdvanceCommittedCursors() throws {
        for key in ["external_events", "external_activities"] {
            let defaults = defaults()
            StateSnapshotStore.save(
                try state(
                    serverTime: 2_000_000_000_000,
                    externalSyncCursorsVersion: 2),
                userID: "user-a",
                defaults: defaults)
            let priorWatermarks = try XCTUnwrap(StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.watermarks)
            XCTAssertGreaterThan(priorWatermarks.eventsSince, 0)
            XCTAssertGreaterThan(priorWatermarks.activitiesSince, 0)
            let ticket = try XCTUnwrap(
                StateSnapshotStore.reserveStateRequest(
                    userID: "user-a", defaults: defaults))

            let encoded = try JSONEncoder().encode(try state(
                serverTime: 2_000_000_100_000,
                externalSyncCursorsVersion: 2))
            var object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: encoded)
                    as? [String: Any])
            object[key] = [["id": 123]]
            let malformed = try JSONSerialization.data(
                withJSONObject: object)

            XCTAssertThrowsError(try JSONDecoder().decode(
                StateResponse.self, from: malformed))
            XCTAssertTrue(StateSnapshotStore.isCurrent(
                ticket, defaults: defaults))
            XCTAssertEqual(
                StateSnapshotStore.load(
                    userID: "user-a", defaults: defaults)?.watermarks,
                priorWatermarks)
        }
    }

    func testManualActivityCursorCapabilityDistinguishesLegacyAndP1Payloads() throws {
        let serverTime = 2_000_000_123_456
        let encoded = try JSONEncoder().encode(
            state(serverTime: serverTime))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "_manual_activity_cursor_capable")

        object.removeValue(forKey: "activities")
        let absent = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(absent.manualActivityCursorCapable)
        XCTAssertEqual(StateSyncWatermarks.next(after: absent).logSince, 0)
        let persistedAbsent = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONEncoder().encode(absent))
        XCTAssertFalse(persistedAbsent.manualActivityCursorCapable)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: persistedAbsent).logSince, 0)

        object["activities"] = NSNull()
        let null = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertFalse(null.manualActivityCursorCapable)
        XCTAssertEqual(StateSyncWatermarks.next(after: null).logSince, 0)

        object["activities"] = []
        let empty = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(empty.manualActivityCursorCapable)
        XCTAssertEqual(
            StateSyncWatermarks.next(after: empty).logSince,
            serverTime - StateSyncWatermarks.overlapMilliseconds)

        object["activities"] = [[
            "id": "manual-a",
            "user_id": "user-a",
            "date": "2020-01-01",
            "type": "walk",
            "title": "Backdated walk",
            "duration_minutes": 30,
            "notes": NSNull(),
            "logged_at": 1_000,
            "source": "manual",
            "deleted_at": NSNull(),
        ]]
        let legacyRow = try JSONDecoder().decode(
            StateResponse.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacyRow.manualActivityCursorCapable)
        XCTAssertEqual(StateSyncWatermarks.next(after: legacyRow).logSince, 0)
    }

    func testMalformedManualActivityDoesNotAdvanceCommittedCursor() throws {
        let defaults = defaults()
        StateSnapshotStore.save(
            try state(serverTime: 2_000_000_000_000),
            userID: "user-a",
            defaults: defaults)
        let priorWatermarks = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.watermarks)
        XCTAssertGreaterThan(priorWatermarks.logSince, 0)
        let ticket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))

        let encoded = try JSONEncoder().encode(
            state(serverTime: 2_000_000_100_000))
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "_manual_activity_cursor_capable")
        object["activities"] = [["id": 123]]
        let malformed = try JSONSerialization.data(withJSONObject: object)

        XCTAssertThrowsError(try JSONDecoder().decode(
            StateResponse.self, from: malformed))
        XCTAssertTrue(StateSnapshotStore.isCurrent(
            ticket, defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.watermarks,
            priorWatermarks)
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            priorWatermarks)
    }

    func testP1DeltaMergeDeliversBackdatedActivityAndAppliesTombstonesIdempotently() throws {
        let defaults = defaults()
        let baseline = try state(serverTime: 2_000_000_000_000)
        let initial = StateResponse(
            plan: baseline.plan,
            plan_version: baseline.plan_version,
            sessions: baseline.sessions,
            sets: [set(id: "set-a")],
            external_events: [event(id: "event-a")],
            external_activities: [externalActivity(id: "external-a")],
            activities: [],
            server_time: baseline.server_time)
        StateSnapshotStore.save(
            initial, userID: "user-a", defaults: defaults)

        let deltaTicket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
            userID: "user-a", defaults: defaults))
        XCTAssertGreaterThan(deltaTicket.watermarks.logSince, 1_000)
        let backdated = activity(id: "manual-a", loggedAt: 1_000)
        let updatedSession = SessionRow(
            id: "session-a",
            date: "2033-05-18",
            status: "complete",
            day_template_id: "day-a",
            updated_at: 2_000_000_000_001,
            attempt: 7)
        let merged = try XCTUnwrap(StateSnapshotStore.commitStateResponse(
            StateResponse(
                plan: nil,
                plan_version: 7,
                sessions: [updatedSession],
                sets: [set(id: "set-a"), set(id: "set-b", loggedAt: 2_000)],
                // P1 deliberately requests these as full collections.
                external_events: [event(id: "event-b")],
                external_activities: [externalActivity(id: "external-b")],
                activities: [backdated],
                server_time: 2_000_000_100_000),
            ticket: deltaTicket,
            defaults: defaults))

        XCTAssertEqual(merged.state.plan?.name, "Cached Plan")
        XCTAssertEqual(merged.state.sessions.first?.status, "complete")
        XCTAssertEqual(Set(merged.state.sets.map(\.id)), ["set-a", "set-b"])
        XCTAssertEqual(merged.state.activities, [backdated])
        XCTAssertEqual(merged.state.external_events.map(\.id), ["event-b"])
        XCTAssertEqual(
            merged.state.external_activities.map(\.id), ["external-b"])
        XCTAssertEqual(
            merged.watermarks?.logSince,
            2_000_000_100_000 - StateSyncWatermarks.overlapMilliseconds)

        let tombstoneResponse = StateResponse(
            plan: nil,
            plan_version: 7,
            sessions: [],
            sets: [set(
                id: "set-a",
                deletedAt: 2_000_000_110_000,
                updatedAt: 2_000_000_110_000)],
            external_events: [],
            external_activities: [],
            activities: [activity(
                id: "manual-a", loggedAt: 1_000,
                deletedAt: 2_000_000_110_000)],
            server_time: 2_000_000_120_000)
        for _ in 0..<2 {
            let ticket = try XCTUnwrap(StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults))
            XCTAssertNotNil(StateSnapshotStore.commitStateResponse(
                tombstoneResponse, ticket: ticket, defaults: defaults))
        }

        let final = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(Set(final.state.sets.map(\.id)), ["set-a", "set-b"])
        XCTAssertNotNil(
            final.state.sets.first { $0.id == "set-a" }?.deleted_at)
        XCTAssertEqual(
            final.state.sets.first { $0.id == "set-a" }?.updated_at,
            2_000_000_110_000)
        XCTAssertTrue(final.state.external_events.isEmpty)
        XCTAssertTrue(final.state.external_activities.isEmpty)
        XCTAssertTrue(final.state.activities.isEmpty)
        XCTAssertEqual(final.state.sessions.first?.status, "complete")
    }

    func testSameAccountResumesCursorButAccountChangeRequiresFullReload() throws {
        let defaults = defaults()
        XCTAssertTrue(StateSyncAccountStore.activate(
            userID: "user-a", defaults: defaults))
        StateSnapshotStore.save(
            try state(
                planName: "A",
                serverTime: 2_000_000_000_000,
                externalSyncCursorsVersion: 2),
            userID: "user-a", defaults: defaults)
        StateSnapshotStore.save(
            try state(
                planName: "B",
                serverTime: 2_000_000_100_000,
                externalSyncCursorsVersion: 2),
            userID: "user-b", defaults: defaults)

        let accountAWatermarks = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults)?.watermarks)
        let accountBWatermarks = try XCTUnwrap(StateSnapshotStore.load(
            userID: "user-b", defaults: defaults)?.watermarks)
        XCTAssertGreaterThan(accountAWatermarks.eventsSince, 0)
        XCTAssertGreaterThan(accountAWatermarks.activitiesSince, 0)
        XCTAssertNotEqual(
            accountAWatermarks.eventsSince,
            accountBWatermarks.eventsSince)

        XCTAssertFalse(StateSyncAccountStore.activate(
            userID: "user-a", defaults: defaults))
        XCTAssertNotEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            .fullReload)

        XCTAssertTrue(StateSyncAccountStore.activate(
            userID: "user-b", defaults: defaults))
        XCTAssertTrue(StateSnapshotStore.requireFullReload(
            userID: "user-b", defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-b", defaults: defaults)?.watermarks,
            .fullReload)
        XCTAssertEqual(
            StateSnapshotStore.load(
                userID: "user-a", defaults: defaults)?.watermarks,
            accountAWatermarks)
    }

    func testLaterReservationRejectsEarlierCommitRegardlessOfServerTime() throws {
        let defaults = defaults()
        let older = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(
            userID: "user-a", defaults: defaults))
        let newer = try XCTUnwrap(StateSnapshotStore.reserveFullStateRequest(
            userID: "user-a", defaults: defaults))

        XCTAssertFalse(StateSnapshotStore.wasSupersededByMutation(
            older, defaults: defaults))

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
        XCTAssertTrue(StateSnapshotStore.wasSupersededByMutation(
            ticket, defaults: defaults))
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
        XCTAssertTrue(StateSnapshotStore.wasSupersededByMutation(
            ticket, defaults: defaults))
        XCTAssertNil(StateSnapshotStore.load(
            userID: "user-a", defaults: defaults))
        XCTAssertEqual(
            StateSnapshotStore.reserveStateRequest(
                userID: "user-a", defaults: defaults)?.watermarks,
            .fullReload)
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
