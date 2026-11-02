import XCTest
@testable import TresFort

/// Importing .fit workout files (docs/plans/endurance-training-load P4).
final class FitImportTests: XCTestCase {
    private func response(deduplicated: Bool = false, duplicateOf: String? = nil,
                          load: Double? = 64, method: String? = "power") -> FitImportResponse {
        FitImportResponse(
            activity: .init(id: "fit:activity:u:1", kind: "ride", date: "2026-10-24",
                            duplicate_of: duplicateOf, effective_load: load, load_method: method),
            deduplicated: deduplicated)
    }

    func testDecodesTheWorkersResponse() throws {
        let json = """
        {"activity":{"id":"fit:activity:u:1","source":"fit","kind":"run","date":"2026-10-25",
          "duplicate_of":null,"effective_load":50,"load_method":"heart_rate","moving_time_sec":1800},
         "deduplicated":false}
        """
        let decoded = try JSONDecoder().decode(FitImportResponse.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.activity.kind, "run")
        XCTAssertEqual(decoded.activity.effective_load, 50)
        XCTAssertFalse(decoded.deduplicated)
    }

    func testSaysWhatHappenedToEachFile() {
        XCTAssertTrue(FitImportOutcome.message(for: response()).hasSuffix(", load 64 from power."))
        XCTAssertTrue(FitImportOutcome.message(for: response()).hasPrefix("Imported Ride on "))
        XCTAssertEqual(FitImportOutcome.message(for: response(deduplicated: true)), "Already imported.")
        XCTAssertEqual(FitImportOutcome.message(for: response(duplicateOf: "intervals:activity:u:9")),
                       "Already in Très Fort from intervals.icu, so that copy is kept.")
        XCTAssertTrue(FitImportOutcome.message(for: response(load: nil, method: nil))
            .hasSuffix("Add your thresholds in Training thresholds to score it."))
    }

    func testExplainsRejectedFiles() {
        XCTAssertEqual(FitImportOutcome.message(for: APIError.http(400, #"{"error":"not_fit"}"#)),
                       "This isn’t a .fit file.")
        XCTAssertEqual(FitImportOutcome.message(for: APIError.http(422, #"{"error":"multisport"}"#)),
                       "Multisport files, such as a triathlon, can’t be imported yet.")
        XCTAssertEqual(FitImportOutcome.message(for: APIError.http(502, "")),
                       "Très Fort couldn’t import it right now. Try again.")
        XCTAssertEqual(FitImportOutcome.message(for: URLError(.notConnectedToInternet)),
                       "Couldn’t reach Très Fort. Nothing was imported; try again.")
    }

    func testMultipartBodyCarriesTheIdAndFile() throws {
        let body = APIClient.fitMultipartBody(Data([0x0e, 0x10]), fileName: "my \"ride\".fit", id: "abc", boundary: "B")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"id\"\r\n\r\nabc\r\n"))
        XCTAssertTrue(text.contains("filename=\"my ride.fit\""))
        XCTAssertTrue(text.hasSuffix("\r\n--B--\r\n"))
    }
}

@MainActor
final class FitImportModelTests: XCTestCase {
    func testImportsEachFileAndKeepsGoingAfterAFailure() async {
        var uploaded: [String] = []
        var refreshed = 0
        let model = FitImportModel(
            jwt: { "jwt" },
            uploader: { _, name, _, _ in
                uploaded.append(name)
                if name == "bad.fit" { throw APIError.http(400, #"{"error":"not_fit"}"#) }
                return FitImportResponse(
                    activity: .init(id: "fit:1", kind: "ride", date: "2026-10-24", duplicate_of: nil,
                                    effective_load: 64, load_method: "power"),
                    deduplicated: false)
            },
            reader: { _ in Data([1]) },
            onImported: { refreshed += 1 })

        await model.importFiles([URL(fileURLWithPath: "/tmp/bad.fit"), URL(fileURLWithPath: "/tmp/ride.fit")])

        XCTAssertEqual(uploaded, ["bad.fit", "ride.fit"])
        XCTAssertEqual(model.outcomes.map(\.imported), [false, true])
        XCTAssertEqual(model.outcomes.first?.message, "This isn’t a .fit file.")
        XCTAssertEqual(refreshed, 1)
        XCTAssertFalse(model.isImporting)
    }

    func testARefusedBearerStopsAndAsksToSignIn() async {
        var refused: [String] = []
        var uploads = 0
        let model = FitImportModel(
            jwt: { "old" },
            uploader: { _, _, _, _ in uploads += 1; throw APIError.http(401, "") },
            reader: { _ in Data([1]) },
            onUnauthorized: { refused.append($0) })

        await model.importFiles([URL(fileURLWithPath: "/tmp/a.fit"), URL(fileURLWithPath: "/tmp/b.fit")])

        XCTAssertEqual(uploads, 1)
        XCTAssertEqual(refused, ["old"])
        XCTAssertEqual(model.outcomes.map(\.message), ["Sign in again, then import this file."])
    }

    func testNothingHappensSignedOut() async {
        var uploads = 0
        let model = FitImportModel(jwt: { nil }, uploader: { _, _, _, _ in
            uploads += 1
            throw URLError(.badURL)
        })
        await model.importFiles([URL(fileURLWithPath: "/tmp/a.fit")])
        XCTAssertEqual(uploads, 0)
        XCTAssertTrue(model.outcomes.isEmpty)
    }
}
