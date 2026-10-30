import Foundation

/// `POST /api/activities/recordings` response for an accepted upload. A 200
/// (`deduplicated`) means an earlier attempt already reached intervals.icu.
struct RecordingUploadResult: Decodable, Equatable {
    let ok: Bool
    let deduplicated: Bool
    let recording_id: String
    let intervals_activity_id: String?
}

protocol RecordingUploadAPI {
    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult
}

extension APIClient: RecordingUploadAPI {
    /// Multipart upload of one finished run as GPX. Retrying the same run is
    /// safe: the server dedupes on its id.
    func uploadRecording(_ run: RecordedRun, jwt: String) async throws -> RecordingUploadResult {
        let boundary = "TresFort-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/activities/recordings")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Device-TZ")
        req.httpBody = Self.recordingMultipartBody(run, gpx: RecordedRunGPX.encode(run), boundary: boundary)
        return try await send(req)
    }

    static func recordingMultipartBody(_ run: RecordedRun, gpx: Data, boundary: String) -> Data {
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
        body.append(Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(run.uploadID).gpx\"\r\n"
             + "Content-Type: application/gpx+xml\r\n\r\n").utf8))
        body.append(gpx)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// Sends every finished run the store holds, oldest first, and removes each
/// one only after the server acknowledges it. One failure doesn't stop the
/// others; failed runs stay for the next attempt.
enum RunRecordingUploader {
    struct Summary: Equatable {
        var uploaded: [UUID] = []
        var failed: [UUID] = []
        /// True when the server rejected the bearer; the caller re-authenticates.
        var unauthorized = false
    }

    static func uploadPending(
        store: RunRecordingStore,
        api: RecordingUploadAPI,
        jwt: String
    ) async throws -> Summary {
        var summary = Summary()
        for run in try store.pendingUploads() {
            do {
                _ = try await api.uploadRecording(run, jwt: jwt)
                try store.remove(id: run.id)
                summary.uploaded.append(run.id)
            } catch let APIError.http(code, _) where code == 401 {
                summary.failed.append(run.id)
                summary.unauthorized = true
                break
            } catch {
                summary.failed.append(run.id)
            }
        }
        return summary
    }
}
