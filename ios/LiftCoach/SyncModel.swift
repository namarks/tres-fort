import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var plan: PlanTree?
    @Published var sets: [SetLog] = []
    @Published var todaySession: SessionRow?
    @Published var selectedDayID: String?
    @Published var loadError: String?
    @Published var isLoading = false

    // Rest timer (local Live Activity arrives in milestone g).
    @Published var restEndDate: Date?
    @Published var restExercise: String = ""

    private let api = APIClient()
    private unowned let auth: AuthModel

    init(auth: AuthModel) { self.auth = auth }

    var todayString: String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }

    var selectedDay: DayTemplate? {
        guard let plan else { return nil }
        return plan.days.first { $0.id == selectedDayID } ?? plan.days.first
    }

    func load() async {
        guard let jwt = auth.jwt else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let state = try await api.getState(jwt: jwt)
            plan = state.plan
            sets = state.sets
            todaySession = state.sessions.first { $0.date == todayString }
            if selectedDayID == nil { selectedDayID = state.plan?.days.first?.id }
            loadError = nil
        } catch {
            handle(error)
        }
    }

    func lastWorkingSet(_ exerciseID: String) -> SetLog? {
        sets.filter { $0.exercise_id == exerciseID && $0.is_warmup == 0 }
            .max { $0.logged_at < $1.logged_at }
    }

    func todaySets(_ exerciseID: String) -> [SetLog] {
        guard let sid = todaySession?.id else { return [] }
        return sets
            .filter { $0.session_id == sid && $0.exercise_id == exerciseID && $0.is_warmup == 0 }
            .sorted { $0.set_index < $1.set_index }
    }

    func logSet(_ ex: TemplateExercise, weight: Double, reps: Int) async {
        guard let jwt = auth.jwt else { return }
        do {
            if todaySession == nil {
                todaySession = try await api.createSession(date: todayString, jwt: jwt)
            }
            guard let session = todaySession else { return }
            let nextIndex = todaySets(ex.exercise_id).count + 1
            let body: [String: Any] = [
                "id": UUID().uuidString,
                "exercise_id": ex.exercise_id,
                "set_index": nextIndex,
                "weight": weight,
                "reps": reps,
            ]
            let res = try await api.logSet(sessionId: session.id, body: body, jwt: jwt)
            if !sets.contains(where: { $0.id == res.set.id }) { sets.append(res.set) }
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        } catch {
            handle(error)
        }
    }

    // MARK: rest timer

    func startRest(seconds: Int, name: String) {
        restExercise = name
        restEndDate = Date().addingTimeInterval(TimeInterval(seconds))
    }
    func addRest(_ seconds: Int) {
        guard let end = restEndDate else { return }
        restEndDate = end.addingTimeInterval(TimeInterval(seconds))
    }
    func skipRest() { restEndDate = nil }

    private func handle(_ error: Error) {
        if case let APIError.http(code, _) = error, code == 401 {
            auth.invalidate()
        } else {
            loadError = error.localizedDescription
        }
    }
}
