import SwiftUI
import UniformTypeIdentifiers

/// Import workout files (.fit) from a bike computer, watch or an app such as
/// Zwift (docs/plans/endurance-training-load P4). The Worker reads each file,
/// keeps the workout with a training load from its power and heart rate, and
/// never stores the file. No AI and no intervals.icu account are needed.

/// `POST /api/activities/fit` response.
struct FitImportResponse: Decodable, Equatable {
    struct Activity: Decodable, Equatable {
        let id: String
        let kind: String
        let date: String
        let duplicate_of: String?
        var effective_load: Double? = nil
        var load_method: String? = nil
    }
    let activity: Activity
    let deduplicated: Bool
}

extension APIClient {
    /// Multipart upload of one .fit file. `id` is the idempotency key, so a
    /// retry of the same file returns the workout the first attempt stored.
    func importFitFile(_ file: Data, fileName: String, id: String, jwt: String) async throws -> FitImportResponse {
        let boundary = "TresFort-\(UUID().uuidString)"
        var req = URLRequest(url: URL(string: baseURL.absoluteString + "/api/activities/fit")!)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        req.httpBody = Self.fitMultipartBody(file, fileName: fileName, id: id, boundary: boundary)
        return try await send(req)
    }

    static func fitMultipartBody(_ file: Data, fileName: String, id: String, boundary: String) -> Data {
        var body = Data()
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"id\"\r\n\r\n\(id)\r\n".utf8))
        // Quotes and line breaks would end the header early.
        let safeName = fileName.filter { $0 != "\"" && !$0.isNewline }
        body.append(Data(
            ("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(safeName)\"\r\n"
             + "Content-Type: application/vnd.ant.fit\r\n\r\n").utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        return body
    }
}

/// What happened to one chosen file.
struct FitImportOutcome: Identifiable, Equatable {
    let id: UUID
    let fileName: String
    let message: String
    let imported: Bool

    /// The words shown for a response from the Worker.
    static func message(for response: FitImportResponse) -> String {
        let activity = response.activity
        if response.deduplicated { return "Already imported." }
        if let winner = activity.duplicate_of {
            return winner.hasPrefix("intervals:")
                ? "Already in Très Fort from intervals.icu, so that copy is kept."
                : "Already in Très Fort, so that copy is kept."
        }
        let what = "\(PendingActivity.label(for: activity.kind)) on \(day(activity.date))"
        guard let load = activity.effective_load else {
            return "Imported \(what). Add your thresholds in Training thresholds to score it."
        }
        let method: String
        switch activity.load_method {
        case "power", "power_summary": method = " from power"
        case "heart_rate": method = " from heart rate"
        case "heart_rate_average": method = " from average heart rate"
        case "pace": method = " from pace"
        default: method = ""
        }
        return "Imported \(what), load \(Int(load.rounded()))\(method)."
    }

    private static let dayFormat: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.setLocalizedDateFormatFromTemplate("d MMM yyyy")
        return f
    }()

    /// "24 Oct 2026" for a civil date, or the date as sent.
    static func day(_ civilDate: String) -> String {
        CalendarProjection.date(from: civilDate).map { dayFormat.string(from: $0) } ?? civilDate
    }

    /// The words shown for a failed upload.
    static func message(for error: Error) -> String {
        guard let api = error as? APIError, let status = api.httpStatus else {
            return "Couldn’t reach Très Fort. Nothing was imported; try again."
        }
        let code = api.httpBody.flatMap { body in
            (try? JSONDecoder().decode([String: String].self, from: Data(body.utf8)))?["error"]
        }
        switch code {
        case "not_fit": return "This isn’t a .fit file."
        case "truncated": return "This file is incomplete or damaged."
        case "not_an_activity": return "This .fit file holds a course or settings, not a workout."
        case "multisport": return "Multisport files, such as a triathlon, can’t be imported yet."
        case "no_data": return "This file has no workout data."
        case "file_too_large": return "This file is too large to import."
        default:
            return status >= 500
                ? "Très Fort couldn’t import it right now. Try again."
                : "This file couldn’t be imported."
        }
    }
}

@MainActor
final class FitImportModel: ObservableObject {
    typealias Uploader = (_ file: Data, _ fileName: String, _ id: String, _ jwt: String) async throws -> FitImportResponse

    @Published private(set) var outcomes: [FitImportOutcome] = []
    @Published private(set) var isImporting = false

    private let jwt: () -> String?
    private let uploader: Uploader
    private let reader: (URL) throws -> Data
    private let onImported: () -> Void
    private let onUnauthorized: (String) -> Void

    init(jwt: @escaping () -> String?,
         uploader: @escaping Uploader,
         reader: @escaping (URL) throws -> Data = FitImportModel.readSecurityScoped,
         onImported: @escaping () -> Void = {},
         onUnauthorized: @escaping (String) -> Void = { _ in }) {
        self.jwt = jwt
        self.uploader = uploader
        self.reader = reader
        self.onImported = onImported
        self.onUnauthorized = onUnauthorized
    }

    convenience init(auth: AuthModel) {
        let accountID = auth.userID
        let api = APIClient()
        self.init(
            jwt: { [weak auth] in
                guard let auth, auth.userID == accountID else { return nil }
                return auth.featureJWT
            },
            uploader: { file, name, id, jwt in try await api.importFitFile(file, fileName: name, id: id, jwt: jwt) },
            onImported: { [weak auth] in auth?.noteAccountStatePersisted(for: accountID) },
            onUnauthorized: { [weak auth] refused in
                guard let auth, auth.userID == accountID, auth.featureJWT == refused else { return }
                auth.requireReauthentication()
            })
    }

    /// Files from the document picker live outside the sandbox until opened.
    nonisolated static func readSecurityScoped(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try Data(contentsOf: url)
    }

    /// Upload each file in turn. One file's failure never stops the others.
    func importFiles(_ urls: [URL]) async {
        guard !isImporting, !urls.isEmpty else { return }
        guard let token = jwt() else { return }
        isImporting = true
        defer { isImporting = false }
        var importedAny = false
        var results: [FitImportOutcome] = []
        for url in urls {
            let name = url.lastPathComponent
            let message: String
            var imported = false
            do {
                let data = try reader(url)
                let response = try await uploader(data, name, UUID().uuidString.lowercased(), token)
                message = FitImportOutcome.message(for: response)
                imported = !response.deduplicated && response.activity.duplicate_of == nil
                importedAny = true
            } catch let error as APIError where error.httpStatus == 401 {
                onUnauthorized(token)
                results.append(FitImportOutcome(id: UUID(), fileName: name,
                    message: "Sign in again, then import this file.", imported: false))
                break
            } catch let error as APIError {
                message = FitImportOutcome.message(for: error)
            } catch {
                message = url.isFileURL && (error as NSError).domain == NSCocoaErrorDomain
                    ? "This file couldn’t be opened."
                    : FitImportOutcome.message(for: error)
            }
            results.append(FitImportOutcome(id: UUID(), fileName: name, message: message, imported: imported))
        }
        outcomes = results
        if importedAny { onImported() }
    }
}

/// Profile → Import workout files.
struct FitImportView: View {
    @StateObject private var model: FitImportModel
    @State private var choosing = false

    init(auth: AuthModel) {
        _model = StateObject(wrappedValue: FitImportModel(auth: auth))
    }

    init(model: FitImportModel) {
        _model = StateObject(wrappedValue: model)
    }

    static let fitType = UTType(filenameExtension: "fit") ?? .data

    var body: some View {
        List {
            Section {
                Text("Choose .fit files exported from a bike computer, a watch, Zwift or another app. Très Fort adds each workout with a training load from its power or heart rate. The file itself isn’t kept.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                Button {
                    choosing = true
                } label: {
                    HStack {
                        Label(model.isImporting ? "Importing…" : "Choose .fit files", systemImage: "doc.badge.plus")
                        if model.isImporting { Spacer(); ProgressView() }
                    }
                }
                .disabled(model.isImporting)
                .accessibilityIdentifier("fitImport.choose")
            } footer: {
                Text("A workout that intervals.icu already sent stays as it is. One that Apple Health also has shows once, from the file.")
            }
            if !model.outcomes.isEmpty {
                Section("Last import") {
                    ForEach(model.outcomes) { outcome in
                        VStack(alignment: .leading, spacing: 3) {
                            Label(outcome.fileName, systemImage: outcome.imported ? "checkmark.circle" : "info.circle")
                                .foregroundStyle(Theme.text)
                            Text(outcome.message).font(.caption).foregroundStyle(Theme.muted)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Import workout files")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .fileImporter(isPresented: $choosing, allowedContentTypes: [Self.fitType, .data],
                      allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            Task { await model.importFiles(urls) }
        }
    }
}
