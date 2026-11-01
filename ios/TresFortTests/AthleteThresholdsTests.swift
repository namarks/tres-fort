import XCTest
@testable import TresFort

final class AthleteThresholdsTests: XCTestCase {
    private func row(_ id: String, sport: String = "run", metric: String = "threshold_pace_s_per_km",
                     value: Double = 300, date: String, created: Int = 1,
                     source: String = "member") -> AthleteThreshold {
        AthleteThreshold(id: id, sport: sport, metric: metric, value: value,
                         effective_date: date, source: source, created_at: created)
    }

    private func day(_ civil: String) -> Date { CalendarProjection.date(from: civil)! }

    func testDecodesTheWorkerShape() throws {
        let json = #"""
        {"thresholds":[{"id":"a","sport":"ride","metric":"ftp_w","value":250,
          "effective_date":"2026-10-01","source":"member","created_at":1793500000000}],
         "current":{"ride":{"ftp_w":250,"threshold_hr":null},"run":{}},"as_of":null}
        """#
        let response = try JSONDecoder().decode(APIClient.AthleteThresholdsResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.thresholds.first?.value, 250)
        XCTAssertEqual(response.thresholds.first?.thresholdMetric, .ftp)
        XCTAssertEqual(response.thresholds.first?.thresholdSport, .ride)
    }

    func testValueInEffectMatchesTheWorker() {
        let rows = [row("a", value: 330, date: "2026-06-01"),
                    row("b", value: 300, date: "2026-09-01"),
                    row("c", value: 290, date: "2026-09-01", created: 2),
                    row("d", value: 280, date: "2026-12-01"),
                    row("ftp", sport: "ride", metric: "ftp_w", value: 250, date: "2026-01-01")]
        func value(on date: String) -> Double? {
            AthleteThresholdHistory.inEffect(rows, sport: .run, metric: .pace, on: date)?.value
        }
        XCTAssertEqual(value(on: "2026-01-01"), 330, "the earliest value covers older workouts")
        XCTAssertEqual(value(on: "2026-07-01"), 330)
        XCTAssertEqual(value(on: "2026-09-01"), 290, "a later entry on the same date wins")
        XCTAssertEqual(value(on: "2026-11-01"), 290)
        XCTAssertEqual(AthleteThresholdHistory.upcoming(rows, sport: .run, metric: .pace, after: "2026-11-01")?.id, "d")
        XCTAssertNil(AthleteThresholdHistory.upcoming(rows, sport: .run, metric: .pace, after: "2026-12-01"))
        XCTAssertNil(AthleteThresholdHistory.inEffect(rows, sport: .run, metric: .heartRate, on: "2026-11-01"))
    }

    func testPaceIsEnteredPerMileAndStoredPerKilometer() {
        var draft = ThresholdDraft(sport: .run, metric: .pace, today: day("2026-11-01"))
        draft.text = "7:15"
        XCTAssertEqual(draft.value(unit: .miles), 270)
        XCTAssertEqual(draft.value(unit: .kilometers), 435)
        XCTAssertEqual(ThresholdFormat.value(270, metric: .pace, unit: .miles), "7:15 /mi")
        XCTAssertEqual(ThresholdFormat.value(270, metric: .pace, unit: .kilometers), "4:30 /km")
        XCTAssertEqual(ThresholdFormat.value(250, metric: .ftp, unit: .miles), "250 W")
        XCTAssertEqual(ThresholdFormat.value(167.7, metric: .heartRate, unit: .miles), "168 bpm")
    }

    func testOutOfRangeOrUnreadableValuesCannotBeSaved() {
        var ftp = ThresholdDraft(sport: .ride, metric: .ftp, today: day("2026-11-01"))
        XCTAssertNil(ftp.problem(unit: .miles), "empty text shows no message")
        XCTAssertFalse(ftp.canSave(unit: .miles))
        ftp.text = "20"
        XCTAssertNotNil(ftp.problem(unit: .miles))
        ftp.text = "250.5"
        XCTAssertNil(ftp.value(unit: .miles))
        ftp.text = " 250 "
        XCTAssertTrue(ftp.canSave(unit: .miles))

        var pace = ThresholdDraft(sport: .run, metric: .pace, today: day("2026-11-01"))
        pace.text = "1:30"
        XCTAssertNil(pace.value(unit: .kilometers))
        XCTAssertEqual(pace.problem(unit: .miles),
                       "Enter a pace such as 7:30, from 3:13 to 32:11 per mile.")
    }

    func testPostBodyHasExactlyTheAcceptedFields() throws {
        var draft = ThresholdDraft(sport: .ride, metric: .heartRate, today: day("2026-10-15"))
        draft.text = "160"
        let input = try XCTUnwrap(draft.input(id: "id-1", unit: .miles))
        XCTAssertEqual(Set(input.body.keys), ["id", "sport", "metric", "value", "effective_date"])
        XCTAssertEqual(input.body["metric"] as? String, "threshold_hr")
        XCTAssertEqual(input.body["value"] as? Double, 160)
        XCTAssertEqual(input.body["effective_date"] as? String, "2026-10-15")
    }

    func testAnUnchangedCorrectionCannotBeSaved() throws {
        let stored = row("a", sport: "ride", metric: "ftp_w", value: 250, date: "2026-10-01")
        var draft = try XCTUnwrap(ThresholdDraft(correcting: stored, unit: .miles))
        XCTAssertEqual(draft.text, "250")
        XCTAssertFalse(draft.canSave(unit: .miles))
        draft.text = "255"
        XCTAssertTrue(draft.canSave(unit: .miles))
    }
}

private let storedFTP = AthleteThreshold(id: "old", sport: "ride", metric: "ftp_w", value: 250,
                                         effective_date: "2026-10-01", source: "member", created_at: 1)

private func savedRow(_ input: AthleteThresholdInput) -> AthleteThreshold {
    AthleteThreshold(id: input.id, sport: input.sport.rawValue, metric: input.metric.rawValue,
                     value: input.value, effective_date: input.effective_date,
                     source: "member", created_at: 2)
}

@MainActor
final class AthleteThresholdsModelTests: XCTestCase {
    private let stored = storedFTP

    func testCorrectionAddsTheNewValueThenRemovesTheOld() async throws {
        var calls: [String] = []
        var changes = 0
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [storedFTP] },
            adder: { input, _ in calls.append("add \(input.value)"); return savedRow(input) },
            remover: { id, _ in calls.append("remove \(id)") },
            onChanged: { changes += 1 })
        await model.load()
        var draft = try XCTUnwrap(ThresholdDraft(correcting: stored, unit: .miles))
        draft.text = "260"

        let ok = await model.save(draft, unit: .miles)

        XCTAssertTrue(ok)
        XCTAssertEqual(calls, ["add 260.0", "remove old"])
        XCTAssertEqual(model.thresholds.map(\.value), [260])
        XCTAssertEqual(changes, 1)
        XCTAssertNil(model.errorMessage)
    }

    func testAFailedRemovalKeepsTheSavedValueAndSaysSo() async throws {
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [storedFTP] },
            adder: { input, _ in savedRow(input) },
            remover: { _, _ in throw URLError(.notConnectedToInternet) })
        await model.load()
        var draft = try XCTUnwrap(ThresholdDraft(correcting: stored, unit: .miles))
        draft.text = "260"

        let ok = await model.save(draft, unit: .miles)

        XCTAssertTrue(ok)
        XCTAssertEqual(Set(model.thresholds.map(\.value)), [250, 260])
        XCTAssertEqual(model.errorMessage,
                       "The new value was saved, but the old one wasn’t removed. Check your connection and try again.")
    }

    func testAFailedSaveChangesNothing() async {
        var changes = 0
        var unauthorized = 0
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [] },
            adder: { _, _ in throw APIError.http(401, "{}") },
            remover: { _, _ in XCTFail("nothing to remove") },
            onChanged: { changes += 1 },
            onUnauthorized: { refused in
                XCTAssertEqual(refused, "jwt")
                unauthorized += 1
            })
        var draft = ThresholdDraft(sport: .run, metric: .heartRate, today: Date())
        draft.text = "170"

        let ok = await model.save(draft, unit: .miles)

        XCTAssertFalse(ok)
        XCTAssertTrue(model.thresholds.isEmpty)
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(unauthorized, 1)
        XCTAssertEqual(model.errorMessage, "Nothing was saved. Sign in again to continue.")
    }

    func testRetryingAnUnconfirmedSaveReusesItsID() async {
        var ids: [String] = []
        var failNext = true
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [] },
            adder: { input, _ in
                ids.append(input.id)
                if failNext { failNext = false; throw URLError(.networkConnectionLost) }
                return savedRow(input)
            },
            remover: { _, _ in })
        var draft = ThresholdDraft(sport: .ride, metric: .ftp, today: Date())
        draft.text = "250"

        let first = await model.save(draft, unit: .miles)
        XCTAssertFalse(first)
        XCTAssertEqual(model.errorMessage, "It may not have been saved. Check your connection and try again.")
        let second = await model.save(draft, unit: .miles)
        XCTAssertTrue(second)
        XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(ids[0], ids[1], "the retry must hit the Worker's idempotent path")

        // A different value is a new row with its own id.
        draft.text = "255"
        _ = await model.save(draft, unit: .miles)
        XCTAssertEqual(ids.count, 3)
        XCTAssertNotEqual(ids[2], ids[1])
    }

    func testARefusedSaveDoesNotPinItsID() async {
        var ids: [String] = []
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [] },
            adder: { input, _ in ids.append(input.id); throw APIError.http(409, #"{"error":"id_conflict"}"#) },
            remover: { _, _ in })
        var draft = ThresholdDraft(sport: .ride, metric: .ftp, today: Date())
        draft.text = "250"
        _ = await model.save(draft, unit: .miles)
        _ = await model.save(draft, unit: .miles)
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
    }

    func testRemoveDropsTheRowAndRefreshes() async {
        var changes = 0
        let model = AthleteThresholdsModel(
            jwt: { "jwt" },
            loader: { _ in [storedFTP] },
            adder: { input, _ in savedRow(input) },
            remover: { _, _ in },
            onChanged: { changes += 1 })
        await model.load()
        await model.remove(stored)
        XCTAssertTrue(model.thresholds.isEmpty)
        XCTAssertEqual(changes, 1)
    }

    func testSignedOutLoadFails() async {
        let model = AthleteThresholdsModel(jwt: { nil }, loader: { _ in XCTFail("no request"); return [] })
        await model.load()
        XCTAssertEqual(model.phase, .failed)
    }
}

final class ActivityLoadDisplayTests: XCTestCase {
    private func activity(load: Double?, method: String?, provider: Int? = nil, source: String = "healthkit",
                          date: String = "2026-11-03", seconds: Int = 3_600) -> ExternalActivity {
        ExternalActivity(
            id: UUID().uuidString, source: source, external_id: "x", date: date, kind: "run", name: nil,
            moving_time_sec: seconds, elapsed_time_sec: nil, distance_m: 10_000, average_watts: nil,
            weighted_avg_watts: nil, average_hr: nil, max_hr: nil, training_load: provider,
            intensity: nil, calories: nil, elevation_gain_m: nil, synced_at: 1, deleted_at: nil,
            effective_load: load, load_method: method)
    }

    func testDecodesEffectiveLoad() throws {
        let json = #"""
        {"id":"healthkit:1","source":"healthkit","external_id":"1","date":"2026-10-24","kind":"run",
         "name":"Run","moving_time_sec":3600,"elapsed_time_sec":3600,"distance_m":10000,
         "average_watts":null,"weighted_avg_watts":null,"average_hr":null,"max_hr":null,
         "training_load":null,"intensity":null,"calories":600,"elevation_gain_m":null,
         "synced_at":5,"deleted_at":null,"effective_load":69,"effective_intensity":83.3,"load_method":"pace"}
        """#
        let decoded = try JSONDecoder().decode(ExternalActivity.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.shownLoad, 69)
        XCTAssertEqual(decoded.effective_intensity, 83.3)
        XCTAssertEqual(decoded.loadMethodLabel, "pace")
    }

    func testLoadAndMethodLabels() {
        XCTAssertEqual(activity(load: 72, method: "provider", provider: 72, source: "intervals").loadMethodLabel, "intervals.icu")
        XCTAssertEqual(activity(load: 72.4, method: "power_summary").shownLoad, 72)
        XCTAssertEqual(activity(load: 72, method: "power_summary").loadMethodLabel, "power")
        XCTAssertEqual(activity(load: 45, method: "heart_rate_average").loadMethodLabel, "avg heart rate")
        // An older Worker sends only the provider's load.
        XCTAssertEqual(activity(load: nil, method: nil, provider: 88, source: "intervals").shownLoad, 88)
        // Unknown stays unknown, never zero.
        XCTAssertNil(activity(load: nil, method: nil).shownLoad)
        XCTAssertNil(activity(load: nil, method: nil).loadMethodLabel)
    }

    func testEnduranceWeeksSumKnownLoads() {
        // Wednesday; the week starts Monday 2026-11-02.
        let summary = EnduranceProgress(activities: [
            activity(load: 69, method: "pace", date: "2026-11-03"),
            activity(load: 45, method: "heart_rate", date: "2026-11-02"),
            activity(load: nil, method: nil, date: "2026-11-02"),
            activity(load: 100, method: "pace", date: "2026-10-28"),
        ], today: "2026-11-04", weekCount: 2)
        XCTAssertEqual(summary.weeks.map(\.load), [100, 114])
        XCTAssertEqual(summary.weeks.map(\.unscored), [0, 1])
        XCTAssertEqual(summary.thisWeekLoad, 114)
        XCTAssertEqual(summary.averageWeekLoad, 100)
        XCTAssertTrue(summary.hasLoad)
        XCTAssertEqual(summary.unscoredCount, 1)
    }
}
