import XCTest
@testable import TresFort

final class ExerciseGroupPresentationTests: XCTestCase {
    private struct Fixture: Decodable {
        let slots: [TemplateExercise]
    }

    private func slots() throws -> [TemplateExercise] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "ExerciseGroups", withExtension: "json"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url)).slots
    }

    func testSelectionRequiresAdjacentOrdinarySlotsAndCannotAbsorbPartOfGroup() throws {
        var slots = try slots()
        XCTAssertNil(ExerciseGroupBlock.selectedMembers([slots[0].id], in: slots))
        XCTAssertNil(ExerciseGroupBlock.selectedMembers([slots[0].id, slots[2].id], in: slots))
        XCTAssertEqual(ExerciseGroupBlock.selectedMembers([slots[1].id, slots[0].id], in: slots)?.map(\.id),
                       Array(slots.prefix(2)).map(\.id))
        slots[0].group_id = "warmup"
        slots[1].group_id = "warmup"
        XCTAssertNil(ExerciseGroupBlock.selectedMembers([slots[1].id, slots[2].id], in: slots))
        XCTAssertNil(ExerciseGroupBlock.selectedMembers([slots[0].id, slots[1].id], in: slots))
    }

    func testGroupCardsAndBlockMovesPreserveMemberOrderAndIndividualRests() throws {
        var slots = try slots()
        for i in 0..<2 {
            slots[i].group_id = "warmup"
            slots[i].group_rest_seconds = 30
            slots[i].group_transition_seconds = 0
        }
        for i in 2..<4 {
            slots[i].group_id = "working"
            slots[i].group_rest_seconds = 60
            slots[i].group_transition_seconds = 15
        }
        let blocks = ExerciseGroupBlock.blocks(slots)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].title, "Superset A")
        XCTAssertTrue(blocks[0].isWarmup)
        XCTAssertFalse(blocks[1].isWarmup)
        XCTAssertEqual(blocks[1].memberLabel(at: 1), "B2")
        XCTAssertEqual(blocks[1].roundRest, 60)
        XCTAssertEqual(blocks[1].transitionRest, 15)
        let reordered = [blocks[1], blocks[0]]
        XCTAssertEqual(ExerciseGroupBlock.slotDestination(of: blocks[0].id, in: reordered), 2)
        XCTAssertEqual(ExerciseGroupBlock.slotDestination(of: blocks[1].id, in: reordered), 0)
        XCTAssertEqual(reordered.flatMap(\.members).map(\.rest_seconds), [120, 75, 45, 90])
        for i in slots.indices {
            slots[i].group_id = nil
            slots[i].group_rest_seconds = nil
            slots[i].group_transition_seconds = nil
        }
        XCTAssertEqual(ExerciseGroupBlock.blocks(slots).count, 4)
        XCTAssertEqual(slots.map(\.rest_seconds), [45, 90, 120, 75])
    }

    private func progress(_ counts: [Int], targets: [Int]? = nil, skipped: Set<Int> = []) -> GroupRunnerProgress {
        GroupRunnerProgress(id: "group", members: counts.enumerated().map { index, count in
            .init(id: "member-\(index)", target: targets?[index] ?? 2,
                  completedIDs: Set((0..<count).map { "saved-\(index)-\($0)" }),
                  skipped: skipped.contains(index))
        })
    }

    func testNextPreviewUsesMinimumProgressAfterManuallyFocusedMember() {
        let group = progress([0, 0, 1])
        // Browsing to B does not make C next: A still needs its first set.
        XCTAssertEqual(group.nextMemberID(afterCompleting: "member-1"), "member-0")
        // C is on physical set 2 while the group is still on round 1.
        XCTAssertEqual(group.nextMemberID(afterCompleting: "member-2"), "member-0")
        XCTAssertEqual(group.round, 1)
        XCTAssertEqual(group.members.map { $0.completedIDs.count }, [0, 0, 1])
    }

    func testNextPreviewCanRepeatCurrentMemberWhenItIsBehind() {
        let group = progress([0, 2, 2], targets: [3, 3, 3])
        XCTAssertEqual(group.nextMemberID(afterCompleting: "member-0"), "member-0")
        XCTAssertEqual(progress([1, 2, 2], targets: [3, 3, 3])
            .nextMemberID(afterCompleting: "member-0"), "member-0",
            "Equal counts retain stored order, matching the live scheduler")
    }

    func testNextPreviewIgnoresSkippedAndCompleteMembers() {
        let group = progress([0, 0, 2, 0], skipped: [1])
        XCTAssertEqual(group.nextMemberID(afterCompleting: "member-0"), "member-3")
        XCTAssertEqual(group.nextMemberID(afterCompleting: "member-1"), "member-0")
        XCTAssertNil(group.nextMemberID(afterCompleting: "member-2"))
        XCTAssertNil(group.nextMemberID(afterCompleting: "missing"))
    }

    func testNextPreviewReenablesOnlyTheManuallyRevisitedSkippedMember() {
        let before = progress([0, 0, 1], skipped: [0, 1])
        XCTAssertEqual(before.nextMemberID, "member-2")
        let next = before.nextMemberID(afterCompleting: "member-0")
        // Logging the explicitly revisited A unskips A, but B stays skipped.
        // A and C then tie at one set: stored order selects A again.
        XCTAssertEqual(next, "member-0")
        let committed = GroupRunnerProgress(id: before.id, members: before.members.map { member in
            .init(id: member.id, target: member.target,
                  completedIDs: member.id == "member-0" ? member.completedIDs.union(["committed-set"]) : member.completedIDs,
                  skipped: member.id == "member-0" ? false : member.skipped)
        })
        XCTAssertEqual(next, committed.nextMemberID)
        XCTAssertEqual(before.members.map(\.skipped), [true, true, false])
        XCTAssertEqual(before.members.map { $0.completedIDs.count }, [0, 0, 1])
    }

    func testNextPreviewEndsAtFinalRoundAndWrapsOnlyForRemainingWork() {
        XCTAssertEqual(progress([1, 0]).nextMemberID(afterCompleting: "member-1"), "member-0")
        XCTAssertNil(progress([2, 1]).nextMemberID(afterCompleting: "member-1"))
        XCTAssertNil(progress([0, 1], skipped: [0]).nextMemberID(afterCompleting: "member-1"))
        XCTAssertNil(progress([2, 2]).nextMemberID)
    }

    func testPreviewMatchesSchedulerAfterDurableCommitWithoutChangingOriginalProgress() {
        let before = progress([1, 0, 1], skipped: [2])
        let next = before.nextMemberID(afterCompleting: "member-1")
        let committed = GroupRunnerProgress(id: before.id, members: before.members.map { member in
            .init(id: member.id, target: member.target,
                  completedIDs: member.id == "member-1" ? member.completedIDs.union(["committed-set"]) : member.completedIDs,
                  skipped: member.skipped)
        })
        XCTAssertEqual(next, committed.nextMemberID)
        XCTAssertEqual(before.members[1].completedIDs, [])
    }

}
