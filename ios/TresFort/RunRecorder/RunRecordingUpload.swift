import Foundation

/// `POST /api/activities/recordings` response for an accepted upload. Tres
/// Fort keeps the run and its route (docs/plans/run-recorder P5) and sends
/// the file on to intervals.icu when the account has a connection;
/// `intervals.status` says which ("uploaded", "not_connected", or "skipped"
/// for a run the member deleted). A 200 (`deduplicated`) means earlier
/// attempts already did both. An older Worker sends no `intervals`, only
/// uploads to intervals.icu, and answers 409 `intervals_not_connected`
/// without a connection.
struct RecordingUploadResult: Decodable, Equatable {
    struct IntervalsCopy: Decodable, Equatable {
        let status: String
    }

    let ok: Bool
    let deduplicated: Bool
    let recording_id: String
    let intervals_activity_id: String?
    var intervals: IntervalsCopy? = nil

    /// Tres Fort kept the run and no copy went to intervals.icu.
    var keptWithoutIntervals: Bool {
        intervals.map { $0.status != "uploaded" } ?? false
    }
}

protocol RecordingUploadAPI {
    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult
}

extension APIClient: RecordingUploadAPI {
    /// Multipart upload of one finished run as TCX. Retrying the same run is
    /// safe: the server dedupes on its id.
    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult {
        let boundary = "TresFort-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/activities/recordings")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        req.httpBody = Self.recordingMultipartBody(run, tcx: RecordedRunTCX.encode(run), boundary: boundary)
        return try await send(req)
    }

    static func recordingMultipartBody(_ run: RecordedRun, tcx: Data, boundary: String) -> Data {
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data(value.utf8))
            body.append(Data("\r\n".utf8))
        }
        field("id", run.uploadID)
        field("date", run.date)
        if let name = run.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            field("name", name)
        }
        if let recovery = run.recovery {
            field("recovery_hr_at_stop", "\(recovery.atStop)")
            if let bpm = recovery.after60s { field("recovery_hr_after_60s", "\(bpm)") }
            if let bpm = recovery.after120s { field("recovery_hr_after_120s", "\(bpm)") }
        }
        // The barometer's climb (P7), in meters to a tenth.
        if let climb = RunAltitude.climb(run), climb.isFinite {
            field("elevation_gain_m", String(format: "%.1f", min(max(climb, 0), 10_000)))
        }
        body.append(Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(run.uploadID).tcx\"\r\n"
             + "Content-Type: application/vnd.garmin.tcx+xml\r\n\r\n").utf8))
        body.append(tcx)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// Sends every finished run the store holds, oldest first, and removes each
/// one only after the server acknowledges it. One failure doesn't stop the
/// others; failed runs stay for the next attempt. Tres Fort keeps each run
/// it accepts, so intervals.icu is optional. A failure that comes with
/// `stored: true` means Tres Fort has the run and only the intervals.icu copy
/// waits; the run stays queued to retry that. With an older Worker that
/// only uploads to intervals.icu, a run Apple Health saved in full leaves the
/// queue when the account has no connection.
enum RunRecordingUploader {
    struct Summary: Equatable {
        var uploaded: [UUID] = []
        var failed: [UUID] = []
        /// True when the server rejected the bearer; the caller re-authenticates.
        var unauthorized = false
        /// Runs an older Worker didn't send because this account has no
        /// intervals.icu connection; Apple Health keeps them.
        var notConnected: [UUID] = []
        /// Uploaded runs Tres Fort kept without an intervals.icu copy.
        var keptWithoutIntervals: [UUID] = []
        /// Failed runs Tres Fort already kept; only the intervals.icu copy
        /// waits.
        var keptAwaitingIntervals: [UUID] = []
    }

    /// A failure after Tres Fort kept the run: only intervals.icu failed.
    static func isKept(_ error: Error) -> Bool {
        guard case let APIError.http(_, body) = error else { return false }
        return body.contains("\"stored\":true")
    }

    /// The Worker's answer when the account has no intervals.icu connection.
    static func isNotConnected(_ error: Error) -> Bool {
        guard case let APIError.http(code, body) = error else { return false }
        return code == 409 && body.contains("\"intervals_not_connected\"")
    }

    /// `waiting` holds runs not to send yet, such as one whose cool-down is
    /// still being measured.
    static func uploadPending(
        store: RunRecordingStore,
        api: RecordingUploadAPI,
        jwt: String,
        waiting: Set<UUID> = []
    ) async throws -> Summary {
        var summary = Summary()
        for run in try store.pendingUploads() where !waiting.contains(run.id) {
            do {
                let result = try await api.uploadRecording(run, jwt: jwt)
                try store.remove(id: run.id)
                summary.uploaded.append(run.id)
                if result.keptWithoutIntervals { summary.keptWithoutIntervals.append(run.id) }
            } catch let APIError.http(code, _) where code == 401 {
                summary.failed.append(run.id)
                summary.unauthorized = true
                break
            } catch let error where isNotConnected(error) && run.savedToHealth == true {
                try store.remove(id: run.id)
                summary.notConnected.append(run.id)
            } catch {
                summary.failed.append(run.id)
                if isKept(error) { summary.keptAwaitingIntervals.append(run.id) }
            }
        }
        return summary
    }
}
