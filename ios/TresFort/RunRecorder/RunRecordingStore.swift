import CryptoKit
import Foundation

enum RunRecordingStoreError: Error, Equatable {
    case damagedRecording(UUID)
}

/// On-device copies of recorded runs, one JSON file per run in an
/// account-scoped directory. A run stays here from its first checkpoint until
/// the server acknowledges its upload, so neither a crash mid-run nor a dead
/// network at the finish loses it.
///
/// Files use `completeUntilFirstUserAuthentication` rather than the `complete`
/// protection of other training data: a run is recorded with the phone locked
/// in a pocket, and `complete` would refuse every checkpoint written then.
final class RunRecordingStore {
    private static let protection = FileProtectionType.completeUntilFirstUserAuthentication
    let rootURL: URL

    init(accountID: String, baseURL: URL? = nil) throws {
        rootURL = try Self.accountDirectory(accountID: accountID, baseURL: baseURL)
        try FileManager.default.createDirectory(
            at: rootURL, withIntermediateDirectories: true,
            attributes: [.protectionKey: Self.protection])
        var root = rootURL
        var resources = URLResourceValues()
        resources.isExcludedFromBackup = true
        try root.setResourceValues(resources)
    }

    /// Account IDs never become path components; a digest does.
    static func accountDirectory(accountID: String, baseURL: URL? = nil) throws -> URL {
        guard let base = baseURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RunRecordings", isDirectory: true) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let digest = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return base.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(digest, isDirectory: true)
    }

    /// Account deletion removes every run that has not uploaded yet.
    static func deleteAccountRecordings(accountID: String, baseURL: URL? = nil) throws {
        let root = try accountDirectory(accountID: accountID, baseURL: baseURL)
        if FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.removeItem(at: root)
        }
    }

    private func fileURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// Atomic replace, so a checkpoint interrupted by a crash leaves the
    /// previous complete copy rather than a truncated file.
    func save(_ run: RecordedRun) throws {
        let data = try JSONEncoder().encode(run)
        try data.write(to: fileURL(for: run.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func load(id: UUID) throws -> RecordedRun? {
        let url = fileURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let run = try? JSONDecoder().decode(RecordedRun.self, from: Data(contentsOf: url)),
              run.id == id, run.schemaVersion == RecordedRun.currentSchemaVersion else {
            throw RunRecordingStoreError.damagedRecording(id)
        }
        return run
    }

    /// Every stored run, oldest first. A damaged file is reported, not
    /// silently skipped, so it can't hide a run the member expects to upload.
    func all() throws -> [RecordedRun] {
        try FileManager.default.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: nil)
            .compactMap { url -> RecordedRun? in
                guard url.pathExtension == "json",
                      let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent) else { return nil }
                return try load(id: id)
            }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// The run still being recorded, if the app stopped before it finished.
    func unfinished() throws -> RecordedRun? {
        try all().last { !$0.isFinished }
    }

    /// Finished runs waiting for the server to acknowledge their upload.
    func pendingUploads() throws -> [RecordedRun] {
        try all().filter(\.isFinished)
    }

    func remove(id: UUID) throws {
        let url = fileURL(for: id)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
