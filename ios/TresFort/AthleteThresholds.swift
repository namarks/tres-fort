import Foundation

// Athlete thresholds (migration 0059, docs/plans/endurance-training-load P2).
// A member's FTP, threshold heart rate and threshold pace, each with the date
// it applies from. The Worker scores every run and ride against the values in
// effect on its date; the app only reads and writes the history.

enum ThresholdSport: String, CaseIterable, Identifiable, Codable {
    case ride, run

    var id: String { rawValue }
    var title: String { self == .ride ? "Cycling" : "Running" }
    var glyph: String { self == .ride ? "bicycle" : "figure.run" }

    /// The metrics each sport carries, matching THRESHOLD_METRICS on the Worker.
    var metrics: [ThresholdMetric] {
        switch self {
        case .ride: return [.ftp, .heartRate]
        case .run: return [.pace, .heartRate]
        }
    }
}

enum ThresholdMetric: String, CaseIterable, Identifiable, Codable {
    case ftp = "ftp_w"
    case heartRate = "threshold_hr"
    case pace = "threshold_pace_s_per_km"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ftp: return "FTP"
        case .heartRate: return "Threshold heart rate"
        case .pace: return "Threshold pace"
        }
    }

    /// Accepted values, matching THRESHOLD_RANGES on the Worker. Pace is in
    /// seconds per kilometer.
    var range: ClosedRange<Double> {
        switch self {
        case .ftp: return 30...2000
        case .heartRate: return 60...230
        case .pace: return 120...1200
        }
    }

    var placeholder: String {
        switch self {
        case .ftp: return "250"
        case .heartRate: return "168"
        case .pace: return "7:30"
        }
    }

    func unitLabel(_ unit: RunDistanceUnit) -> String {
        switch self {
        case .ftp: return "W"
        case .heartRate: return "bpm"
        case .pace: return "/\(unit.abbreviation)"
        }
    }

    /// What the value means, for the editor's footer.
    func help(for sport: ThresholdSport) -> String {
        switch self {
        case .ftp:
            return "The power you can hold for about an hour. Rides with power are scored against it."
        case .heartRate:
            return sport == .ride
                ? "Your heart rate at threshold on the bike. Rides without power are scored against it."
                : "Your heart rate at threshold when running. Runs with heart rate are scored against it."
        case .pace:
            return "The pace you can hold for about an hour. Runs without heart rate are scored against it."
        }
    }
}

struct AthleteThreshold: Decodable, Identifiable, Equatable {
    let id: String
    let sport: String
    let metric: String
    let value: Double
    /// YYYY-MM-DD: the value applies from this civil date.
    let effective_date: String
    /// member / coach / intervals.
    let source: String
    let created_at: Int

    var thresholdSport: ThresholdSport? { ThresholdSport(rawValue: sport) }
    var thresholdMetric: ThresholdMetric? { ThresholdMetric(rawValue: metric) }
}

enum AthleteThresholdHistory {
    /// One metric's rows, newest effective date first (newest entry wins a tie).
    static func rows(_ all: [AthleteThreshold], sport: ThresholdSport,
                     metric: ThresholdMetric) -> [AthleteThreshold] {
        all.filter { $0.sport == sport.rawValue && $0.metric == metric.rawValue }
            .sorted { a, b in
                a.effective_date != b.effective_date ? a.effective_date > b.effective_date
                    : a.created_at != b.created_at ? a.created_at > b.created_at : a.id > b.id
            }
    }

    /// The row in effect on `date`, as the Worker picks it: the latest row on
    /// or before the date, else the earliest row, which also covers older
    /// workouts.
    static func inEffect(_ all: [AthleteThreshold], sport: ThresholdSport,
                         metric: ThresholdMetric, on date: String) -> AthleteThreshold? {
        let mine = rows(all, sport: sport, metric: metric)
        return mine.first { $0.effective_date <= date } ?? mine.last
    }

    /// The next row that takes over after `date`, if one is already set.
    static func upcoming(_ all: [AthleteThreshold], sport: ThresholdSport,
                         metric: ThresholdMetric, after date: String) -> AthleteThreshold? {
        rows(all, sport: sport, metric: metric).last { $0.effective_date > date }
    }
}

enum ThresholdFormat {
    /// "250 W", "168 bpm", or "7:15 /mi" for a pace stored per kilometer.
    static func value(_ value: Double, metric: ThresholdMetric, unit: RunDistanceUnit) -> String {
        switch metric {
        case .ftp, .heartRate:
            return "\(Int(value.rounded())) \(metric.unitLabel(unit))"
        case .pace:
            return RunPaceInput.text(secondsPerKm: Int(value.rounded()), unit: unit) + " " + metric.unitLabel(unit)
        }
    }

    /// The editor's text for a stored value: "250", "168" or "7:15".
    static func input(_ value: Double, metric: ThresholdMetric, unit: RunDistanceUnit) -> String {
        metric == .pace ? RunPaceInput.text(secondsPerKm: Int(value.rounded()), unit: unit)
            : "\(Int(value.rounded()))"
    }
}

/// One threshold while the member types it. Saving always adds a row; a
/// correction adds the new row and then removes the one it replaces.
struct ThresholdDraft: Equatable {
    let sport: ThresholdSport
    let metric: ThresholdMetric
    var text: String
    var date: Date
    /// The row this draft corrects, if any.
    let replacing: AthleteThreshold?

    init(sport: ThresholdSport, metric: ThresholdMetric, today: Date) {
        self.sport = sport
        self.metric = metric
        text = ""
        date = today
        replacing = nil
    }

    init?(correcting row: AthleteThreshold, unit: RunDistanceUnit) {
        guard let sport = row.thresholdSport, let metric = row.thresholdMetric,
              let date = CalendarProjection.date(from: row.effective_date) else { return nil }
        self.sport = sport
        self.metric = metric
        text = ThresholdFormat.input(row.value, metric: metric, unit: unit)
        self.date = date
        replacing = row
    }

    var dateString: String { CalendarProjection.dateString(date) }

    /// The value to store (pace in seconds per kilometer), or nil when the
    /// text isn't a number in range.
    func value(unit: RunDistanceUnit) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let value: Double?
        switch metric {
        case .ftp, .heartRate:
            value = Int(trimmed).map(Double.init)
        case .pace:
            value = RunPaceInput.seconds(trimmed).map {
                Double(RunPaceInput.secondsPerKm($0, unit: unit))
            }
        }
        guard let value, metric.range.contains(value) else { return nil }
        return value
    }

    /// Why the draft can't be saved, or nil. Empty text has no message; Save
    /// just stays off.
    func problem(unit: RunDistanceUnit) -> String? {
        if text.trimmingCharacters(in: .whitespaces).isEmpty || value(unit: unit) != nil { return nil }
        switch metric {
        case .ftp: return "Enter whole watts from 30 to 2000."
        case .heartRate: return "Enter beats per minute from 60 to 230."
        case .pace:
            let fastest = RunPaceInput.text(secondsPerKm: Int(metric.range.lowerBound), unit: unit)
            let slowest = RunPaceInput.text(secondsPerKm: Int(metric.range.upperBound), unit: unit)
            return "Enter a pace such as \(metric.placeholder), from \(fastest) to \(slowest) per \(unit.spokenName)."
        }
    }

    /// Nothing to save when a correction changes neither value nor date.
    func canSave(unit: RunDistanceUnit) -> Bool {
        guard let value = value(unit: unit) else { return false }
        guard let replacing else { return true }
        return value != replacing.value || dateString != replacing.effective_date
    }

    /// The POST body: a fresh client UUID as the idempotency key.
    func input(id: String = UUID().uuidString.lowercased(), unit: RunDistanceUnit) -> AthleteThresholdInput? {
        guard let value = value(unit: unit) else { return nil }
        return AthleteThresholdInput(id: id, sport: sport, metric: metric, value: value,
                                     effective_date: dateString)
    }
}

struct AthleteThresholdInput: Equatable {
    let id: String
    let sport: ThresholdSport
    let metric: ThresholdMetric
    let value: Double
    let effective_date: String

    /// The same value from the same date, whatever its id.
    func isRetry(of other: AthleteThresholdInput) -> Bool {
        sport == other.sport && metric == other.metric && value == other.value
            && effective_date == other.effective_date
    }

    /// Exactly the fields POST /api/me/thresholds accepts; it rejects others.
    var body: [String: Any] {
        ["id": id, "sport": sport.rawValue, "metric": metric.rawValue,
         "value": value, "effective_date": effective_date]
    }
}

extension APIClient {
    struct AthleteThresholdsResponse: Decodable { let thresholds: [AthleteThreshold] }
    struct AthleteThresholdResult: Decodable { let threshold: AthleteThreshold }
    struct AthleteThresholdDeleted: Decodable { let ok: Bool }

    /// GET /api/me/thresholds — the member's live thresholds.
    func athleteThresholds(jwt: String) async throws -> [AthleteThreshold] {
        let response: AthleteThresholdsResponse = try await get("api/me/thresholds", jwt: jwt)
        return response.thresholds
    }

    /// POST /api/me/thresholds — idempotent on the client id. The Worker
    /// rescores the member's activities before it answers.
    func addAthleteThreshold(_ input: AthleteThresholdInput, jwt: String) async throws -> AthleteThreshold {
        let response: AthleteThresholdResult = try await post("api/me/thresholds", body: input.body, jwt: jwt)
        return response.threshold
    }

    /// DELETE /api/me/thresholds/:id — soft delete; repeating it succeeds.
    func deleteAthleteThreshold(id: String, jwt: String) async throws {
        let _: AthleteThresholdDeleted = try await delete("api/me/thresholds/\(id)", jwt: jwt)
    }
}

/// Loads and edits the member's thresholds. Every successful change asks the
/// app to refresh, because the Worker has already rescored activities.
@MainActor
final class AthleteThresholdsModel: ObservableObject {
    enum Phase: Equatable { case loading, ready, failed }

    @Published private(set) var thresholds: [AthleteThreshold] = []
    @Published private(set) var phase: Phase = .loading
    @Published private(set) var isSaving = false
    @Published var errorMessage: String?

    private let jwt: () -> String?
    private let loader: (String) async throws -> [AthleteThreshold]
    private let adder: (AthleteThresholdInput, String) async throws -> AthleteThreshold
    private let remover: (String, String) async throws -> Void
    private let onChanged: () -> Void
    /// Called with the bearer a request was refused with, so the owner can
    /// ignore a 401 that predates a renewed sign-in.
    private let onUnauthorized: (String) -> Void
    /// The last value that failed to save. Saving the same value again reuses
    /// its id, so a POST that committed but lost its answer is not added twice.
    private var unconfirmed: AthleteThresholdInput?

    init(jwt: @escaping () -> String?,
         loader: ((String) async throws -> [AthleteThreshold])? = nil,
         adder: ((AthleteThresholdInput, String) async throws -> AthleteThreshold)? = nil,
         remover: ((String, String) async throws -> Void)? = nil,
         onChanged: @escaping () -> Void = {},
         onUnauthorized: @escaping (String) -> Void = { _ in }) {
        let api = APIClient()
        self.jwt = jwt
        if let loader {
            self.loader = loader
        } else {
            self.loader = { token in try await api.athleteThresholds(jwt: token) }
        }
        if let adder {
            self.adder = adder
        } else {
            self.adder = { input, token in try await api.addAthleteThreshold(input, jwt: token) }
        }
        if let remover {
            self.remover = remover
        } else {
            self.remover = { id, token in try await api.deleteAthleteThreshold(id: id, jwt: token) }
        }
        self.onChanged = onChanged
        self.onUnauthorized = onUnauthorized
    }

    /// Scoped to the signed-in account that opened the screen.
    convenience init(auth: AuthModel) {
        let accountID = auth.userID
        self.init(
            jwt: { [weak auth] in
                guard let auth, auth.userID == accountID else { return nil }
                return auth.featureJWT
            },
            onChanged: { [weak auth] in auth?.noteAccountStatePersisted(for: accountID) },
            onUnauthorized: { [weak auth] refused in
                // Only the bearer that was refused may end the session; a
                // renewed or re-signed-in bearer stays.
                guard let auth, auth.userID == accountID, auth.featureJWT == refused else { return }
                auth.requireReauthentication()
            })
    }

    func load() async {
        guard let token = jwt() else { phase = .failed; return }
        if thresholds.isEmpty { phase = .loading }
        do {
            thresholds = try await loader(token)
            phase = .ready
        } catch {
            handle(error, token: token)
            if thresholds.isEmpty { phase = .failed }
        }
    }

    /// Adds the draft's value, then removes the row it corrects. Returns true
    /// when the new value was saved.
    func save(_ draft: ThresholdDraft, unit: RunDistanceUnit) async -> Bool {
        guard !isSaving, let fresh = draft.input(unit: unit), let token = jwt() else { return false }
        let input = unconfirmed.map { $0.isRetry(of: fresh) ? $0 : fresh } ?? fresh
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            let saved = try await adder(input, token)
            unconfirmed = nil
            thresholds.removeAll { $0.id == saved.id }
            thresholds.append(saved)
            if let old = draft.replacing {
                do {
                    try await remover(old.id, token)
                    thresholds.removeAll { $0.id == old.id }
                } catch {
                    handle(error, token: token, prefix: "The new value was saved, but the old one wasn’t removed")
                }
            }
            onChanged()
            return true
        } catch {
            // A refusal stored nothing; anything else may have committed.
            unconfirmed = Self.isRejection(error) ? nil : input
            handle(error, token: token, prefix: Self.isRejection(error)
                   ? "Nothing was saved" : "It may not have been saved")
            return false
        }
    }

    func remove(_ row: AthleteThreshold) async {
        guard !isSaving, let token = jwt() else { return }
        isSaving = true
        defer { isSaving = false }
        errorMessage = nil
        do {
            try await remover(row.id, token)
            thresholds.removeAll { $0.id == row.id }
            onChanged()
        } catch {
            handle(error, token: token, prefix: "It wasn’t removed")
        }
    }

    private func handle(_ error: Error, token: String, prefix: String? = nil) {
        if case let APIError.http(code, _) = error, code == 401 { onUnauthorized(token) }
        let reason = Self.reason(error)
        errorMessage = prefix.map { "\($0). \(reason)" } ?? reason
    }

    /// The Worker answered and refused, so the row was not stored.
    static func isRejection(_ error: Error) -> Bool {
        if case let APIError.http(code, _) = error { return (400..<500).contains(code) }
        return false
    }

    static func reason(_ error: Error) -> String {
        if error is URLError { return "Check your connection and try again." }
        if case let APIError.http(code, _) = error {
            switch code {
            case 401: return "Sign in again to continue."
            case 400: return "The server didn’t accept that value."
            default: return "The server couldn’t do that right now. Try again."
            }
        }
        return "Something went wrong. Try again."
    }
}
