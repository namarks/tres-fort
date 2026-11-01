import Foundation
import XCTest
@testable import TresFort

/// Away dates in the app (docs/plans/coach-free-planning P0): reading the
/// plan's trips and the request fields the editor sends.
final class AwayDatesTests: XCTestCase {
    private func date(_ ymd: String) -> Date { CalendarProjection.date(from: ymd)! }

    private let trip = PlanTrip(id: "trip-1", start: "2026-12-20", end: "2026-12-27",
                                type: "travel", can_train_light: false, note: "Family visit")

    func testPlanListsAwayDatesInDateOrder() {
        let meta = #"{"schedule":{"version":1,"week":{}},"trips":[{"id":"b","start":"2027-02-01","end":"2027-02-03","type":"injury"},{"id":"a","start":"2026-12-20","end":"2026-12-27","type":"travel","can_train_light":false,"note":"Family visit"}]}"#
        let plan = PlanTree(id: "plan", name: "Plan", version: 3, workouts: [], meta: meta)
        XCTAssertEqual(plan.awayDates.map(\.id), ["a", "b"])
        XCTAssertEqual(plan.awayDates.first?.note, "Family visit")
        XCTAssertEqual(plan.awayDates.first?.can_train_light, false)
        XCTAssertNil(plan.awayDates.last?.can_train_light)
        XCTAssertEqual(PlanTree(id: "plan", name: "Plan", version: 1, workouts: [], meta: nil).awayDates, [])
    }

    func testNewAwayDatesSendEveryField() {
        var draft = AwayDatesDraft(today: date("2026-11-01"))
        XCTAssertTrue(draft.isNew)
        XCTAssertTrue(draft.canSave)
        draft.setStart(date("2026-12-20"))
        XCTAssertEqual(draft.endString, "2026-12-20", "The last day follows a later first day")
        draft.setEnd(date("2026-12-27"))
        draft.kind = .rest
        draft.note = "  Cabin  "
        let fields = draft.fields
        XCTAssertEqual(fields["start"] as? String, "2026-12-20")
        XCTAssertEqual(fields["end"] as? String, "2026-12-27")
        XCTAssertEqual(fields["type"] as? String, "rest")
        XCTAssertEqual(fields["can_train_light"] as? Bool, true)
        XCTAssertEqual(fields["note"] as? String, "Cabin")

        let plain = AwayDatesDraft(today: date("2026-11-01"))
        XCTAssertNil(plain.fields["note"], "An empty note isn't sent")
    }

    func testEditingSendsOnlyWhatChanged() {
        var draft = AwayDatesDraft(trip: trip)
        XCTAssertFalse(draft.isNew)
        XCTAssertEqual(draft.startString, "2026-12-20")
        XCTAssertEqual(draft.endString, "2026-12-27")
        XCTAssertEqual(draft.kind, .travel)
        XCTAssertFalse(draft.canTrainLight)
        XCTAssertTrue(draft.fields.isEmpty)
        XCTAssertFalse(draft.canSave, "Nothing to save until something changes")

        draft.setEnd(date("2026-12-28"))
        draft.canTrainLight = true
        XCTAssertEqual(Set(draft.fields.keys), ["end", "can_train_light"])
        XCTAssertEqual(draft.fields["end"] as? String, "2026-12-28")
        XCTAssertTrue(draft.canSave)

        draft.note = ""
        XCTAssertEqual(draft.fields["note"] as? String, "", "Clearing the note sends an empty note")
    }

    func testLastDayNeverPrecedesFirstDay() {
        var draft = AwayDatesDraft(trip: trip)
        draft.setEnd(date("2026-12-01"))
        XCTAssertEqual(draft.endString, "2026-12-20")
        draft.setStart(date("2027-01-05"))
        XCTAssertEqual(draft.endString, "2027-01-05")
        XCTAssertNil(draft.problem)
    }

    func testLongNoteCantBeSaved() {
        var draft = AwayDatesDraft(today: date("2026-11-01"))
        draft.note = String(repeating: "x", count: AwayDatesDraft.noteLimit + 1)
        XCTAssertEqual(draft.problem, "Keep the note under 500 characters.")
        XCTAssertFalse(draft.canSave)
    }

    func testRowText() {
        XCTAssertEqual(AwayDatesText.detail(trip), "Travel · no training")
        let light = PlanTrip(id: "b", start: "2027-02-01", end: "2027-02-01", type: "injury",
                             can_train_light: nil, note: nil)
        XCTAssertEqual(AwayDatesText.detail(light), "Injury")
        XCTAssertFalse(AwayDatesText.range(light).contains("–"), "One day reads as one date")
        XCTAssertTrue(AwayDatesText.range(trip).contains("–"))
    }
}
