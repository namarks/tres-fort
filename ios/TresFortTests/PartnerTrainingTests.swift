import XCTest
@testable import TresFort

@MainActor
final class PartnerTrainingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2000)
    private func steps() -> [PartnerStep] {
        [.init(slotID: "a", set: 1, name: "Squat", restSeconds: 30),
         .init(slotID: "a", set: 2, name: "Squat", restSeconds: 30),
         .init(slotID: "b", set: 1, name: "Bench", restSeconds: 0)]
    }
    private func coordinator() -> PartnerCoordinator {
        var value = PartnerCoordinator(steps: steps())
        value.receive(.init(), from: .host, now: now)
        value.receive(.init(), from: .partner, now: now)
        return value
    }
    func testInvitationExpiresAndFingerprintCannotMatchAnotherAccountOrInvitation() throws {
        let invitation = PartnerInvitation(id: UUID(), now: now)
        XCTAssertEqual(PartnerInvitation.parse(invitation.code, now: now), invitation)
        XCTAssertNil(PartnerInvitation.parse(invitation.code, now: now.addingTimeInterval(121)))
        XCTAssertNil(PartnerInvitation.parse("not an invitation", now: now))
        XCTAssertEqual(invitation.fingerprint(accountID: "host"), invitation.fingerprint(accountID: "host"))
        XCTAssertNotEqual(invitation.fingerprint(accountID: "host"), invitation.fingerprint(accountID: "partner"))
        XCTAssertNotEqual(invitation.fingerprint(accountID: "host"), PartnerInvitation(id: invitation.id, now: now).fingerprint(accountID: "host"))
    }
    func testOneLaneNeverStartsRestAndBothMustFinishBeforeTheNextSet() {
        var value = coordinator()
        value.receive(.init(logged: ["a:1"]), from: .host, now: now)
        XCTAssertEqual(value.state.stepIndex, 0); XCTAssertNil(value.state.restUntil)
        value.receive(.init(logged: ["a:1"]), from: .partner, now: now.addingTimeInterval(10))
        XCTAssertEqual(value.state.restUntil, now.addingTimeInterval(40))
        value.reconcile(now: now.addingTimeInterval(39)); XCTAssertEqual(value.state.stepIndex, 0)
        value.reconcile(now: now.addingTimeInterval(40)); XCTAssertEqual(value.state.stepIndex, 1)
    }
    func testUndoCancelsRestAndKeepsTheOtherLaneLogged() {
        var value = coordinator()
        value.receive(.init(logged: ["a:1"]), from: .host, now: now)
        value.receive(.init(logged: ["a:1"]), from: .partner, now: now)
        value.receive(.init(), from: .partner, now: now.addingTimeInterval(3))
        XCTAssertNil(value.state.restUntil); XCTAssertEqual(value.state.stepIndex, 0)
        XCTAssertEqual(value.state.host.logged, ["a:1"])
        value.receive(.init(logged: ["a:1"]), from: .partner, now: now.addingTimeInterval(8))
        XCTAssertEqual(value.state.restUntil, now.addingTimeInterval(38))
    }
    func testReconnectUndoRewindsWithoutRepeatingAlreadyReleasedRests() {
        var value = coordinator()
        for lane in PartnerLane.allCases { value.receive(.init(logged: ["a:1", "a:2"]), from: lane, now: now) }
        value.reconcile(now: now.addingTimeInterval(30))
        value.reconcile(now: now.addingTimeInterval(60))
        XCTAssertEqual(value.state.stepIndex, 2)
        value.disconnect(.partner, now: now.addingTimeInterval(61))
        value.receive(.init(logged: ["a:2"]), from: .partner, now: now.addingTimeInterval(62))
        XCTAssertEqual(value.state.stepIndex, 0)
        value.receive(.init(logged: ["a:1", "a:2"]), from: .partner, now: now.addingTimeInterval(63))
        XCTAssertEqual(value.state.stepIndex, 2); XCTAssertNil(value.state.restUntil)
    }
    func testDroppedLaneWaitsButAClosedLaneNeverReopens() {
        var value = coordinator()
        value.receive(.init(logged: ["a:1"]), from: .host, now: now)
        value.disconnect(.partner, now: now)
        value.reconcile(now: now.addingTimeInterval(300))
        XCTAssertEqual(value.state.stepIndex, 0); XCTAssertNil(value.state.restUntil)
        value.close(.partner, now: now)
        XCTAssertEqual(value.state.restUntil, now.addingTimeInterval(30))
        value.receive(.init(), from: .partner, now: now)
        XCTAssertTrue(value.state.partner.closed)
        value.reconcile(now: now.addingTimeInterval(30)); XCTAssertEqual(value.state.stepIndex, 1)
    }
    func testUndoClearsSharedSkipAndStaleEchoCannotRestoreIt() {
        var value = coordinator()
        value.receive(.init(logged: ["a:1"]), from: .host, now: now)
        value.skipCurrent(now: now)
        XCTAssertEqual(value.state.skipped, ["a:1"])
        value.receive(.init(), from: .host, now: now)
        XCTAssertTrue(value.state.skipped.isEmpty)
        value.receive(.init(skipped: ["a:1"]), from: .partner, now: now)
        XCTAssertTrue(value.state.skipped.isEmpty)
        XCTAssertNil(value.state.restUntil)
    }
    private func offer() throws -> PartnerOffer {
        let group = UUID().uuidString
        let slots: [[String: Any]] = (0..<2).map { index in
            ["id": UUID().uuidString, "exercise_id": "squat", "exercise_name": "Squat",
             "exercise_unit": "lb", "exercise_modality": "barbell", "order_index": index, "target_sets": 2, "target_reps": 8,
             "rest_seconds": 90, "target_weight": 80, "target_weight_unit": "lb", "is_warmup": index,
             "group_id": group, "group_rest_seconds": 60, "group_transition_seconds": 10,
             "progression": "{\"type\":\"double\"}", "cues": "Controlled", "target_rpe": 8,
             "target_reps_max": 12]
        }
        let data = try JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "name": "Together",
            "order_index": 0, "exercises": slots])
        let workout = try JSONDecoder().decode(Workout.self, from: data)
        return .init(id: UUID(), hostName: "Host", planID: UUID().uuidString, planVersion: 1, workout: workout)
    }
    func testFullCopyPreservesGroupsAndWarmupsWhileSeedingOnlyOwnWorkingWeightAndUnit() throws {
        let offer = try offer()
        let history = [SetLog(id: "set", session_id: "own-session", exercise_id: "squat", template_exercise_id: nil,
            set_index: 1, weight: 40, reps: 8, rpe: nil, is_warmup: 0, logged_at: 10,
            duration_s: nil, is_timed: 0, deleted_at: nil, weight_unit: "kg")]
        let draft = PartnerDraft.make(offer: offer, plan: nil, history: history)
        XCTAssertNil(draft.request.expected_plan_id); XCTAssertEqual(draft.request.expected_version, 0)
        XCTAssertNotEqual(draft.request.workout_id, offer.workout.id)
        XCTAssertEqual(draft.request.slots[0].target_weight, 40); XCTAssertEqual(draft.request.slots[0].target_weight_unit, "kg")
        XCTAssertEqual(draft.request.slots[1].target_weight, 80); XCTAssertEqual(draft.request.slots[1].target_weight_unit, "lb")
        XCTAssertEqual(draft.request.slots[0].group_id, draft.request.slots[1].group_id)
        XCTAssertNotEqual(draft.request.slots[0].group_id, offer.workout.exercises[0].group_id)
        XCTAssertEqual(draft.request.slots[0].progression, "{\"type\":\"double\"}")
        XCTAssertEqual(draft.request.slots[0].cues, "Controlled"); XCTAssertEqual(draft.request.slots[0].target_reps_max, 12)
        XCTAssertEqual(offer.steps.map(\.set), [1, 1, 2, 2]); XCTAssertEqual(offer.steps.map(\.restSeconds), [10, 60, 10, 0])
        XCTAssertEqual(Set(offer.steps.map(\.id)).count, 4)
    }
    func testCheckpointIsAccountScopedAndUsesCompareAndSwap() throws {
        let name = "PartnerTests.\(UUID().uuidString)"
        let defaults = LocalPersistence(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: defaults.trainingStore.directory) }
        let offer = try offer()
        let original = PartnerCheckpoint(id: offer.id, lane: .host, offer: offer, name: "Host", phase: .ready, slotMap: [:])
        XCTAssertTrue(PartnerCheckpointStore.replace(original, expected: nil, accountID: "one", defaults: defaults))
        XCTAssertEqual(PartnerCheckpointStore.load("one", defaults: defaults), original)
        XCTAssertNil(PartnerCheckpointStore.load("two", defaults: defaults))
        var closing = original; closing.phase = .cancelling
        XCTAssertTrue(PartnerCheckpointStore.replace(closing, expected: original, accountID: "one", defaults: defaults))
        XCTAssertFalse(PartnerCheckpointStore.replace(nil, expected: original, accountID: "one", defaults: defaults))
        XCTAssertEqual(PartnerCheckpointStore.load("one", defaults: defaults)?.phase, .cancelling)
    }
}
