import XCTest
@testable import TresFort

@MainActor
final class StationLinkTests: XCTestCase {
    private func target(slot: String = "slot-1", set: Int = 1, reps: Int = 8) -> StationLinkTarget {
        StationLinkTarget(slotID: slot, setNumber: set, exercise: .squat, exerciseName: "Back Squat", targetReps: reps)
    }

    private func completion(_ arm: StationLinkArm, reps: Int = 8, partial: Bool = false,
                            event: UUID = UUID()) -> StationLinkCompletion {
        StationLinkCompletion(armID: arm.armID, eventID: event, reps: reps,
                              leftCount: nil, rightCount: nil, partial: partial)
    }

    // MARK: pairing and protocol

    func testDiscoveryTagIsAFilterDerivedFromTheKey() {
        let key = Data(repeating: 7, count: 32)
        let tag = StationLink.discoveryTag(key: key)
        XCTAssertEqual(tag, StationLink.discoveryTag(key: key))
        XCTAssertNotEqual(tag, StationLink.discoveryTag(key: Data(repeating: 8, count: 32)))
        XCTAssertEqual(tag.count, 24)
        XCTAssertLessThanOrEqual(StationLink.serviceType.count, 15)
    }

    func testOnlyAKeyHolderCanAnswerTheChallengeForItsOwnRole() {
        let key = Data(repeating: 1, count: 32)
        let phoneNonce = StationLink.newNonce(), ipadNonce = StationLink.newNonce()
        XCTAssertEqual(phoneNonce.count, 32)
        XCTAssertNotEqual(phoneNonce, ipadNonce)
        // The iPad answers the iPhone's challenge.
        let proof = StationLink.proof(key: key, responderRole: "station",
                                      challengerNonce: phoneNonce, responderNonce: ipadNonce)
        XCTAssertTrue(StationLink.verify(proof, key: key, responderRole: "station",
                                         challengerNonce: phoneNonce, responderNonce: ipadNonce))
        XCTAssertFalse(StationLink.verify(proof, key: Data(repeating: 2, count: 32), responderRole: "station",
                                          challengerNonce: phoneNonce, responderNonce: ipadNonce),
                       "A peer that only copied the public tag has no valid proof")
        XCTAssertFalse(StationLink.verify(proof, key: key, responderRole: "controller",
                                          challengerNonce: phoneNonce, responderNonce: ipadNonce),
                       "A proof cannot be reflected back as the other role")
        XCTAssertFalse(StationLink.verify(proof, key: key, responderRole: "station",
                                          challengerNonce: StationLink.newNonce(), responderNonce: ipadNonce),
                       "A proof cannot be replayed against a new challenge")
        XCTAssertFalse(StationLink.verify(proof, key: key, responderRole: "station",
                                          challengerNonce: Data(), responderNonce: ipadNonce))
    }

    func testSealedMessagesCannotBeForgedReflectedOrReplayed() throws {
        let key = Data(repeating: 1, count: 32)
        let phoneNonce = StationLink.newNonce(), ipadNonce = StationLink.newNonce()
        let sessionKey = StationLink.sessionKey(key: key, controllerNonce: phoneNonce, stationNonce: ipadNonce)
        XCTAssertNotEqual(sessionKey, StationLink.sessionKey(key: Data(repeating: 2, count: 32),
                                                             controllerNonce: phoneNonce, stationNonce: ipadNonce),
                          "A relay that only forwarded the challenge cannot derive the session key")
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 1, exercise: .squat,
                                 exerciseName: "Back Squat", targetReps: 5)
        let sealed = try XCTUnwrap(StationLink.seal(.arm(arm), sessionKey: sessionKey,
                                                    senderRole: "controller", counter: 1))
        let frame = try XCTUnwrap(JSONSerialization.jsonObject(with: sealed) as? [String: Any])
        let ciphertext = try XCTUnwrap(Data(base64Encoded: try XCTUnwrap(frame["sealed"] as? String)))
        XCTAssertNil(ciphertext.range(of: Data("Back Squat".utf8)), "A relay cannot read the message")
        let opened = try XCTUnwrap(StationLink.open(sealed, sessionKey: sessionKey,
                                                    senderRole: "controller", after: 0))
        XCTAssertEqual(opened.message, .arm(arm))
        XCTAssertEqual(opened.counter, 1)
        XCTAssertNil(StationLink.open(sealed, sessionKey: sessionKey, senderRole: "controller", after: 1),
                     "A message cannot be replayed")
        XCTAssertNil(StationLink.open(sealed, sessionKey: sessionKey, senderRole: "station", after: 0),
                     "A message cannot be reflected back to its sender")
        let forged = try XCTUnwrap(StationLink.seal(.completion(completion(arm)),
                                                    sessionKey: Data(repeating: 9, count: 32),
                                                    senderRole: "station", counter: 2))
        XCTAssertNil(StationLink.open(forged, sessionKey: sessionKey, senderRole: "station", after: 0))
        XCTAssertNil(StationLink.open(try StationLinkMessage.completion(completion(arm)).encoded(),
                                      sessionKey: sessionKey, senderRole: "station", after: 0),
                     "An unsealed message is never accepted after the handshake")
    }

    func testMessagesRoundTripAndRejectOtherProtocolVersions() throws {
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 2, exercise: .curl,
                                 exerciseName: "Dumbbell Curl", targetReps: 10)
        let messages: [StationLinkMessage] = [
            .arm(arm), .disarm(armID: arm.armID),
            .progress(StationLinkProgress(armID: arm.armID, count: 3, leftCount: 3, rightCount: 2, status: "Tracking")),
            .completion(completion(arm, reps: 9)), .station(.cameraOff, armID: nil),
            .challenge(StationLink.newNonce()), .proof(Data(repeating: 3, count: 32)),
        ]
        for message in messages {
            XCTAssertEqual(StationLinkMessage.decode(try message.encoded()), message)
        }
        let future = Data(#"{"version":99,"message":{"disarm":{"armID":"\#(arm.armID.uuidString)"}}}"#.utf8)
        XCTAssertNil(StationLinkMessage.decode(future))
        XCTAssertNil(StationLinkMessage.decode(Data("not json".utf8)))
    }

    func testOnlyCountableMovementsMatch() {
        XCTAssertEqual(StationExercise.match(exerciseName: "Back Squat"), .squat)
        XCTAssertEqual(StationExercise.match(exerciseName: "Goblet squat"), .squat)
        XCTAssertEqual(StationExercise.match(exerciseName: "Barbell Bench Press"), .benchPress)
        XCTAssertEqual(StationExercise.match(exerciseName: "Incline Dumbbell Bench Press"), .benchPress)
        XCTAssertEqual(StationExercise.match(exerciseName: "Hammer Curl"), .curl)
        XCTAssertNil(StationExercise.match(exerciseName: "Bulgarian Split Squat"))
        XCTAssertNil(StationExercise.match(exerciseName: "Jump Squat"))
        XCTAssertNil(StationExercise.match(exerciseName: "Lying Leg Curl"))
        XCTAssertNil(StationExercise.match(exerciseName: "Wrist Curl"))
        XCTAssertNil(StationExercise.match(exerciseName: "Deadlift"))
        XCTAssertNil(StationExercise.match(exerciseName: "Single-Arm Dumbbell Bench Press"))
        XCTAssertNil(StationExercise.match(exerciseName: "Single-Arm Cable Curl"))
        XCTAssertNil(StationExercise.match(exerciseName: "Alternating Dumbbell Curl"))
        XCTAssertNil(StationExercise.match(exerciseName: "Skater Squat"))
        XCTAssertNil(StationExercise.match(exerciseName: "Cossack Squat"))
        XCTAssertNil(StationExercise.match(exerciseName: "Jefferson Curl"), "Spinal flexion, not an elbow curl")
        XCTAssertNil(StationExercise.match(exerciseName: "Concentration Curl"), "One arm, though catalogued bilateral")
        XCTAssertNil(StationExercise.match(exerciseName: "Shrimp Squat"))
        XCTAssertNil(StationExercise.match(exerciseName: "Dumbbell Curl", unilateral: true),
                     "Per-side reps stay manual whatever the name")
        XCTAssertNil(StationExercise.match(exerciseName: "Squat hold", modality: "timed"))
    }

    // MARK: set end on the iPad

    func testSetEndsOnlyAfterTheCountHoldsSteadyAndNeverAtTargetAlone() {
        var detector = StationSetEndDetector()
        XCTAssertFalse(detector.observe(count: 0, status: .ready, at: 0))
        XCTAssertFalse(detector.observe(count: 0, status: .ready, at: 10), "No reps never finishes a set")
        for (index, time) in [11.0, 13, 15, 17, 19, 21, 23, 25].enumerated() {
            XCTAssertFalse(detector.observe(count: index + 1, status: .ready, at: time))
        }
        XCTAssertFalse(detector.observe(count: 8, status: .ready, at: 28.9))
        XCTAssertTrue(detector.observe(count: 8, status: .ready, at: 29.1))
        XCTAssertFalse(detector.observe(count: 8, status: .ready, at: 40), "Finishes exactly once")
    }

    func testSetDoesNotEndMidRepOrWithAnotherPersonInView() {
        var detector = StationSetEndDetector()
        _ = detector.observe(count: 0, status: .ready, at: 0)
        _ = detector.observe(count: 3, status: .ready, at: 1)
        XCTAssertFalse(detector.observe(count: 3, status: .moving, at: 6))
        XCTAssertFalse(detector.observe(count: 3, status: .multiplePeople, at: 7))
        XCTAssertFalse(detector.observe(count: 3, status: .trackingLost, at: 10.9),
                       "Movement or another person restarts the window")
        XCTAssertTrue(detector.observe(count: 3, status: .trackingLost, at: 11.1))
    }

    func testAnUncountedRepAttemptRestartsTheSettleWindow() {
        var detector = StationSetEndDetector()
        _ = detector.observe(count: 0, status: .ready, at: 0)
        _ = detector.observe(count: 4, status: .ready, at: 1)
        XCTAssertFalse(detector.observe(count: 4, status: .moving, at: 5.5), "Another attempt has started")
        XCTAssertFalse(detector.observe(count: 4, status: .ready, at: 6),
                       "Returning without a counted rep does not end the set at once")
        XCTAssertTrue(detector.observe(count: 4, status: .ready, at: 9.6))
    }

    func testATrailingArmKeepsTheSetOpen() {
        var detector = StationSetEndDetector()
        _ = detector.observe(count: 0, leftCount: 0, rightCount: 0, status: .ready, at: 0)
        _ = detector.observe(count: 5, leftCount: 5, rightCount: 3, status: .ready, at: 1)
        XCTAssertFalse(detector.observe(count: 5, leftCount: 5, rightCount: 4, status: .ready, at: 4.5),
                       "The other arm's rep is a change even though the shown count holds")
        XCTAssertFalse(detector.observe(count: 5, leftCount: 5, rightCount: 4, status: .ready, at: 8))
        XCTAssertTrue(detector.observe(count: 5, leftCount: 5, rightCount: 4, status: .ready, at: 8.6))
    }

    func testAnExtraRepRestartsTheSettleWindow() {
        var detector = StationSetEndDetector()
        _ = detector.observe(count: 0, status: .ready, at: 0)
        _ = detector.observe(count: 5, status: .ready, at: 1)
        XCTAssertFalse(detector.observe(count: 6, status: .ready, at: 4.5))
        XCTAssertFalse(detector.observe(count: 6, status: .ready, at: 8))
        XCTAssertTrue(detector.observe(count: 6, status: .ready, at: 8.6))
    }

    // MARK: iPhone acceptance

    func testCompletionsForOtherSetsDuplicatesAndPartialCountsAreGuarded() {
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 1, exercise: .squat,
                                 exerciseName: "Back Squat", targetReps: 5)
        let stale = StationLinkCompletion(armID: UUID(), eventID: UUID(), reps: 5, leftCount: nil, rightCount: nil, partial: false)
        XCTAssertNil(StationLinkPolicy.proposal(for: stale, arm: arm, seenEvents: []))
        XCTAssertNil(StationLinkPolicy.proposal(for: completion(arm), arm: nil, seenEvents: []))
        XCTAssertNil(StationLinkPolicy.proposal(for: completion(arm, reps: 0), arm: arm, seenEvents: []))
        let seen = completion(arm)
        XCTAssertNil(StationLinkPolicy.proposal(for: seen, arm: arm, seenEvents: [seen.eventID]))

        let full = StationLinkPolicy.proposal(for: completion(arm, reps: 6), arm: arm, seenEvents: [])
        XCTAssertEqual(full?.reps, 6)
        XCTAssertEqual(full?.logsAutomatically, true)
        let partial = StationLinkPolicy.proposal(for: completion(arm, partial: true), arm: arm, seenEvents: [])
        XCTAssertEqual(partial?.logsAutomatically, false, "A partial count waits for a tap")
        let uneven = StationLinkPolicy.proposal(
            for: StationLinkCompletion(armID: arm.armID, eventID: UUID(), reps: 8, leftCount: 8, rightCount: 4,
                                       partial: false), arm: arm, seenEvents: [])
        XCTAssertEqual(uneven?.logsAutomatically, false, "Arms that counted differently wait for a tap")
        XCTAssertEqual(uneven?.sidesDiffer, true)
        let even = StationLinkPolicy.proposal(
            for: StationLinkCompletion(armID: arm.armID, eventID: UUID(), reps: 8, leftCount: 8, rightCount: 8,
                                       partial: false), arm: arm, seenEvents: [])
        XCTAssertEqual(even?.logsAutomatically, true)
    }

    func testProposalLogsOnlyIntoTheSlotAndSetItWasCountedFor() throws {
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 2, exercise: .squat,
                                 exerciseName: "Back Squat", targetReps: 5)
        let proposal = try XCTUnwrap(StationLinkPolicy.proposal(for: completion(arm), arm: arm, seenEvents: []))
        XCTAssertTrue(StationLinkPolicy.canCommit(proposal, currentSlotID: "s", currentSetNumber: 2, currentExerciseName: "Back Squat", entryBlocked: false))
        XCTAssertFalse(StationLinkPolicy.canCommit(proposal, currentSlotID: "s", currentSetNumber: 3, currentExerciseName: "Back Squat", entryBlocked: false))
        XCTAssertFalse(StationLinkPolicy.canCommit(proposal, currentSlotID: "other", currentSetNumber: 2, currentExerciseName: "Back Squat", entryBlocked: false))
        XCTAssertFalse(StationLinkPolicy.canCommit(proposal, currentSlotID: "s", currentSetNumber: 2, currentExerciseName: "Back Squat", entryBlocked: true))
        XCTAssertFalse(StationLinkPolicy.canCommit(proposal, currentSlotID: "s", currentSetNumber: 2,
                                                   currentExerciseName: "Front Squat", entryBlocked: false),
                       "A swap in the same slot never takes the old exercise's count")
    }

    func testSwappingTheExerciseInASlotReArmsAndDropsItsCount() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        controller.receive(.completion(completion(arm, reps: 5, partial: true)))
        XCTAssertNotNil(controller.proposal)
        controller.request(StationLinkTarget(slotID: "slot-1", setNumber: 1, exercise: .squat,
                                             exerciseName: "Front Squat", targetReps: 8))
        XCTAssertNil(controller.proposal)
        XCTAssertNotEqual(controller.arm?.armID, arm.armID)
        XCTAssertEqual(controller.arm?.exerciseName, "Front Squat")
    }

    func testControllerArmsEachSetFreshlyAndDropsCountsWhenTheRunnerMovesOn() throws {
        let controller = StationLinkController()
        controller.request(target(set: 1))
        let first = try XCTUnwrap(controller.arm)
        controller.request(target(set: 1))
        XCTAssertEqual(controller.arm?.armID, first.armID, "An unchanged target keeps its arm")

        controller.receive(.completion(completion(first, reps: 7)))
        XCTAssertEqual(controller.proposal?.reps, 7)
        XCTAssertEqual(controller.proposal?.setNumber, 1)

        // Logged by hand: the runner advanced to set 2 before the count was used.
        controller.request(target(set: 2))
        XCTAssertNil(controller.proposal)
        let second = try XCTUnwrap(controller.arm)
        XCTAssertNotEqual(second.armID, first.armID)
        controller.receive(.completion(completion(first, reps: 7)))
        XCTAssertNil(controller.proposal, "A late count for set 1 cannot land on set 2")

        controller.request(nil)
        XCTAssertNil(controller.arm)
    }

    func testDismissedCountIsNeverReplayedAndTheSetIsCountedAgain() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        let event = completion(arm, reps: 4)
        controller.receive(.completion(event))
        controller.dismissProposal()
        XCTAssertNil(controller.proposal)
        let fresh = try XCTUnwrap(controller.arm)
        XCTAssertNotEqual(fresh.armID, arm.armID)
        XCTAssertEqual(fresh.setNumber, arm.setNumber)
        controller.receive(.completion(event))
        XCTAssertNil(controller.proposal)
        controller.receive(.completion(completion(fresh, reps: 5)))
        XCTAssertEqual(controller.proposal?.reps, 5)
    }

    func testFinishedProposalIsNotReofferedAndKeepsTheArm() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        let event = completion(arm, reps: 8)
        controller.receive(.completion(event))
        XCTAssertEqual(controller.proposal?.logsAutomatically, true)
        controller.finishProposal(event.eventID)
        XCTAssertNil(controller.proposal)
        XCTAssertEqual(controller.arm?.armID, arm.armID)
        controller.receive(.completion(event))
        XCTAssertNil(controller.proposal)
    }

    func testMinimizingDisarmsButKeepsACountWaitingForATap() throws {
        let controller = StationLinkController()
        controller.request(target())
        controller.pause()
        XCTAssertNil(controller.arm, "A minimized runner leaves the iPad unarmed")

        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        controller.receive(.completion(completion(arm, reps: 6, partial: true)))
        controller.pause()
        XCTAssertEqual(controller.proposal?.reps, 6, "The counted set survives minimizing")
        controller.request(target())
        XCTAssertEqual(controller.proposal?.reps, 6, "Resuming on the same set keeps it")
    }

    func testAReconnectedIPadIsNotReArmedForASpentSet() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        XCTAssertEqual(controller.armToResend?.armID, arm.armID)
        let event = completion(arm, reps: 5, partial: true)
        controller.receive(.completion(event))
        XCTAssertNil(controller.armToResend, "A count waiting for a tap keeps the iPad idle")
        controller.finishProposal(event.eventID) // Edit hands the count to LOG SET
        XCTAssertNil(controller.armToResend, "An edited set is not counted again")
        controller.request(target(set: 2))
        XCTAssertNotNil(controller.armToResend, "The next set is armed")
    }

    func testUndoRecountsASpentArmOnTheSameSet() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        let event = completion(arm, reps: 8)
        controller.receive(.completion(event))
        controller.finishProposal(event.eventID)
        controller.recount()
        let fresh = try XCTUnwrap(controller.arm)
        XCTAssertNotEqual(fresh.armID, arm.armID, "Undo asks the iPad to count the set again")
        XCTAssertEqual(fresh.setNumber, arm.setNumber)
        XCTAssertEqual(controller.armToResend?.armID, fresh.armID)
        controller.recount()
        XCTAssertEqual(controller.arm?.armID, fresh.armID, "A live arm is left alone")
    }

    func testUnsavedCountWaitsForATapInsteadOfVanishing() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        let event = completion(arm, reps: 8)
        controller.receive(.completion(event))
        controller.holdProposal(event.eventID)
        XCTAssertEqual(controller.proposal?.eventID, event.eventID)
        XCTAssertEqual(controller.proposal?.logsAutomatically, false)
        XCTAssertEqual(controller.proposal?.reps, 8)
        XCTAssertEqual(controller.arm?.armID, arm.armID)
        controller.finishProposal(event.eventID)
        XCTAssertNil(controller.proposal)
    }

    func testLoggedSetStaysUndoableUntilTheNextCount() throws {
        let controller = StationLinkController()
        controller.request(target())
        let logged = StationLinkLoggedSet(setID: "set-1", slotID: "slot-1", setNumber: 1, reps: 8)
        controller.recordLogged(logged)
        controller.request(nil)
        XCTAssertEqual(controller.lastLogged, logged, "Undo stays available through rest")
        controller.request(target(set: 2))
        XCTAssertEqual(controller.lastLogged, logged)
        let next = try XCTUnwrap(controller.arm)
        controller.receive(.completion(completion(next, reps: 6)))
        XCTAssertNil(controller.lastLogged)
        XCTAssertEqual(controller.proposal?.reps, 6)
        controller.clearLogged()
        controller.stop()
        XCTAssertNil(controller.proposal)
    }

    func testProgressFromAnotherArmIsIgnored() throws {
        let controller = StationLinkController()
        controller.request(target())
        let arm = try XCTUnwrap(controller.arm)
        controller.receive(.progress(StationLinkProgress(armID: UUID(), count: 9, leftCount: nil, rightCount: nil, status: "Ready")))
        XCTAssertNil(controller.progress)
        controller.receive(.progress(StationLinkProgress(armID: arm.armID, count: 2, leftCount: nil, rightCount: nil, status: "Ready")))
        XCTAssertEqual(controller.progress?.count, 2)
    }

    // MARK: iPad station

    func testStationCountsOnlyTheArmedSetAndReportsOnce() {
        let station = StationLinkStation()
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 1, exercise: .squat,
                                 exerciseName: "Back Squat", targetReps: 3)
        XCTAssertFalse(station.observe(count: 1, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 0))
        station.receive(.arm(arm))
        XCTAssertEqual(station.arm, arm)
        XCTAssertFalse(station.isCounting, "Counting waits for the camera trial to start")
        station.beginCounting()
        XCTAssertTrue(station.isCounting)
        XCTAssertFalse(station.observe(count: 0, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 0))
        XCTAssertFalse(station.observe(count: 3, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 5))
        XCTAssertTrue(station.observe(count: 3, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 9.5))
        XCTAssertFalse(station.isCounting)
        XCTAssertFalse(station.observe(count: 3, leftCount: nil, rightCount: nil, status: .ready, partial: false, at: 20))

        station.receive(.disarm(armID: UUID()))
        XCTAssertEqual(station.arm, arm, "Only the current arm can be withdrawn")
        station.receive(.disarm(armID: arm.armID))
        XCTAssertNil(station.arm)
    }

    func testStationIgnoresCountsAndCompletionsFromPeers() {
        let station = StationLinkStation()
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 1, exercise: .curl,
                                 exerciseName: "Curl", targetReps: 3)
        station.receive(.completion(completion(arm)))
        station.receive(.progress(StationLinkProgress(armID: arm.armID, count: 1, leftCount: 1, rightCount: 0, status: "Ready")))
        XCTAssertNil(station.arm)
        XCTAssertFalse(station.isCounting)
    }

    func testAbandonedOrEmptyTrialStopsWithoutACount() {
        let station = StationLinkStation()
        let arm = StationLinkArm(armID: UUID(), slotID: "s", setNumber: 1, exercise: .squat,
                                 exerciseName: "Back Squat", targetReps: 3)
        station.receive(.arm(arm))
        station.beginCounting()
        XCTAssertFalse(station.trialEnded(count: 0, leftCount: nil, rightCount: nil, partial: true))
        XCTAssertFalse(station.isCounting)
        station.beginCounting()
        XCTAssertTrue(station.isCounting, "An empty trial can retry the same arm")
        XCTAssertTrue(station.trialEnded(count: 2, leftCount: nil, rightCount: nil, partial: true))
        XCTAssertFalse(station.isCounting)
        station.beginCounting()
        station.abandon()
        XCTAssertFalse(station.isCounting)
        XCTAssertEqual(station.arm, arm)
    }
}
