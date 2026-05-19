import SwiftUI

@MainActor
final class SyncModel: ObservableObject {
    @Published var plan: PlanTree?
    @Published var sets: [SetLog] = []
    @Published var sessions: [SessionRow] = []
    @Published var catalog: [ExerciseCatalog] = []
    @Published var todaySession: SessionRow?
    @Published var selectedDayID: String?
    @Published var loadError: String?
    @Published var isLoading = false

    // Rest timer (local Live Activity arrives in milestone g).
    @Published var restEndDate: Date?
    @Published var restExercise: String = ""
    @Published var restTotal: Int = 0

    // Guided workout runner.
    @Published var running = false
    @Published var finished = false
    @Published var exerciseIndex = 0
    @Published var weight: Double = 0
    @Published var reps: Int = 0

    // Timers.
    @Published var workoutStart: Date?      // whole-session stopwatch
    @Published var timedActive = false      // a timed exercise is running
    @Published var timedEndDate: Date?
    private var setClock = Date()           // when the current set began

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
            sessions = state.sessions
            todaySession = state.sessions.first { $0.date == todayString }
            if selectedDayID == nil { selectedDayID = state.plan?.days.first?.id }
            if catalog.isEmpty {
                catalog = (try? await api.getExercises(jwt: jwt)) ?? []
            }
            loadError = nil
        } catch {
            handle(error)
        }
    }

    /// Live (non-deleted) working sets for an exercise.
    private func live(_ exerciseID: String) -> [SetLog] {
        sets.filter {
            $0.exercise_id == exerciseID && $0.is_warmup == 0 && $0.deleted_at == nil
        }
    }

    func lastWorkingSet(_ exerciseID: String) -> SetLog? {
        live(exerciseID).max { $0.logged_at < $1.logged_at }
    }

    func todaySets(_ exerciseID: String) -> [SetLog] {
        guard let sid = todaySession?.id else { return [] }
        return live(exerciseID)
            .filter { $0.session_id == sid }
            .sorted { $0.set_index < $1.set_index }
    }

    func exerciseName(_ id: String) -> String {
        catalog.first { $0.id == id }?.name ?? id
    }

    // MARK: history aggregation

    struct SessionStat: Identifiable {
        let id: String          // session id
        let date: String
        let est1RM: Double
        let topWeight: Double
        let topReps: Int
        let volume: Double
        let setCount: Int
        let avgDuration: Int
    }

    private func epley(_ w: Double, _ r: Int) -> Double { w * (1 + Double(r) / 30) }

    /// Exercise ids that have any logged set, most-recent first.
    var loggedExerciseIDs: [String] {
        let live = sets.filter { $0.is_warmup == 0 && $0.deleted_at == nil }
        let byId = Dictionary(grouping: live, by: \.exercise_id)
        return byId.keys.sorted {
            (byId[$0]?.map(\.logged_at).max() ?? 0) >
            (byId[$1]?.map(\.logged_at).max() ?? 0)
        }
    }

    func history(for exerciseID: String) -> [SessionStat] {
        let dateBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.date) })
        let grouped = Dictionary(grouping: live(exerciseID), by: \.session_id)
        return grouped.compactMap { sid, rows -> SessionStat? in
            guard let date = dateBySession[sid], !rows.isEmpty else { return nil }
            let top = rows.max { epley($0.weight, $0.reps) < epley($1.weight, $1.reps) }!
            let durs = rows.compactMap(\.duration_s)
            return SessionStat(
                id: sid, date: date,
                est1RM: epley(top.weight, top.reps).rounded(),
                topWeight: top.weight, topReps: top.reps,
                volume: rows.reduce(0) { $0 + $1.weight * Double($1.reps) },
                setCount: rows.count,
                avgDuration: durs.isEmpty ? 0 : durs.reduce(0, +) / durs.count)
        }
        .sorted { $0.date < $1.date }
    }

    func logSet(_ ex: TemplateExercise, weight: Double, reps: Int,
                durationOverride: Int? = nil) async {
        guard let jwt = auth.jwt else { return }
        let duration = durationOverride
            ?? max(0, Int(Date().timeIntervalSince(setClock)))
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
                "duration_s": duration,
            ]
            let res = try await api.logSet(sessionId: session.id, body: body, jwt: jwt)
            if !sets.contains(where: { $0.id == res.set.id }) { sets.append(res.set) }
            setClock = Date()
            startRest(seconds: ex.rest_seconds, name: ex.exercise_name)
        } catch {
            handle(error)
        }
    }

    // MARK: runner

    var exercises: [TemplateExercise] { selectedDay?.exercises ?? [] }
    var currentExercise: TemplateExercise? {
        exercises.indices.contains(exerciseIndex) ? exercises[exerciseIndex] : nil
    }
    /// 1-based number of the set about to be performed for the current exercise.
    var currentSetNumber: Int {
        guard let ex = currentExercise else { return 1 }
        return todaySets(ex.exercise_id).count + 1
    }

    func startWorkout() {
        running = true
        finished = false
        exerciseIndex = 0
        workoutStart = Date()
        seedInputs()
    }

    /// Seed weight/reps from last time → plan target → default. Resets the
    /// per-set clock (a new set begins on arrival at an exercise).
    private func seedInputs() {
        timedActive = false
        timedEndDate = nil
        setClock = Date()
        guard let ex = currentExercise else { return }
        let last = lastWorkingSet(ex.exercise_id)
        weight = last?.weight ?? ex.target_weight ?? 45
        reps = last?.reps ?? ex.target_reps
    }

    // MARK: timed exercises (plank, holds)

    func startTimedSet() {
        guard let ex = currentExercise, ex.isTimed else { return }
        setClock = Date()
        timedActive = true
        timedEndDate = Date().addingTimeInterval(TimeInterval(ex.target_reps))
    }

    /// End a timed set — `held` seconds actually performed (auto at 0, or
    /// early via STOP). Logs reps=held, duration=held.
    func finishTimedSet(held: Int) async {
        guard let ex = currentExercise, timedActive else { return }
        timedActive = false
        timedEndDate = nil
        await logSet(ex, weight: 0, reps: held, durationOverride: held)
        if isComplete(ex) {
            if let next = nextIncompleteIndex { jump(to: next) } else { finished = true }
        }
    }

    func adjustWeight(_ delta: Double) { weight = max(0, weight + delta) }
    func adjustReps(_ delta: Int) { reps = max(0, reps + delta) }

    func setsDone(_ ex: TemplateExercise) -> Int { todaySets(ex.exercise_id).count }
    func isComplete(_ ex: TemplateExercise) -> Bool { setsDone(ex) >= ex.target_sets }
    var allComplete: Bool { !exercises.isEmpty && exercises.allSatisfy { isComplete($0) } }

    /// First not-yet-complete exercise after the current one (wraps), so a
    /// completed lift never traps you and order is flexible.
    var nextIncompleteIndex: Int? {
        let n = exercises.count
        guard n > 0 else { return nil }
        for offset in 1...n {
            let i = (exerciseIndex + offset) % n
            if !isComplete(exercises[i]) { return i }
        }
        return nil
    }

    func jump(to index: Int) {
        guard exercises.indices.contains(index) else { return }
        exerciseIndex = index
        seedInputs()
    }

    func logCurrentSet() async {
        guard let ex = currentExercise else { return }
        await logSet(ex, weight: weight, reps: reps)   // also starts rest timer
        if isComplete(ex) {
            if let next = nextIncompleteIndex { jump(to: next) }
            else { finished = true }
        }
    }

    /// Manual "move on" — next exercise in order; falls back to any
    /// remaining work, else ends.
    func skip() {
        if exerciseIndex + 1 < exercises.count { jump(to: exerciseIndex + 1) }
        else if let next = nextIncompleteIndex { jump(to: next) }
        else { finished = true }
    }

    func previous() {
        guard exerciseIndex > 0 else { return }
        exerciseIndex -= 1
        seedInputs()
    }

    func finishWorkout() async {
        if let jwt = auth.jwt, let sid = todaySession?.id {
            todaySession = try? await api.completeSession(sessionId: sid, jwt: jwt)
        }
        running = false
        finished = false
        workoutStart = nil
        timedActive = false
        timedEndDate = nil
        skipRest()
        await load()
    }

    // MARK: rest timer

    /// Name of the next not-complete exercise (for the rest screen's UP NEXT).
    var upNextName: String {
        if let i = nextIncompleteIndex { return exercises[i].exercise_name }
        return "Done"
    }

    func removeSet(_ set: SetLog) async {
        guard let jwt = auth.jwt else { return }
        do {
            try await api.deleteSet(setId: set.id, jwt: jwt)
            sets.removeAll { $0.id == set.id }
        } catch { handle(error) }
    }

    func startRest(seconds: Int, name: String) {
        restExercise = name
        restTotal = seconds
        let end = Date().addingTimeInterval(TimeInterval(seconds))
        restEndDate = end
        RestLiveActivity.start(exercise: name, endDate: end, upNext: upNextName)
    }
    func addRest(_ seconds: Int) {
        guard let end = restEndDate else { return }
        let newEnd = end.addingTimeInterval(TimeInterval(seconds))
        restEndDate = newEnd
        RestLiveActivity.update(endDate: newEnd, upNext: upNextName)
    }
    func skipRest() {
        restEndDate = nil
        setClock = Date()   // next set begins when rest ends
        RestLiveActivity.endNow()
    }

    // MARK: calendar projection (read-only future calendar)

    /// Plan day_template ids (for dangling-schedule detection).
    var planTemplateIDs: Set<String> {
        Set(plan?.days.map(\.id) ?? [])
    }

    /// Real cached sessions keyed by YYYY-MM-DD. If multiple sessions share
    /// a date, prefer the most "advanced" one (completed > in_progress >
    /// planned > skipped) so the calendar shows the strongest signal.
    var sessionsByDate: [String: SessionRow] {
        func rank(_ s: String) -> Int {
            switch s {
            case "completed":   return 4
            case "in_progress": return 3
            case "planned":     return 2
            case "skipped":     return 1
            default:            return 0
            }
        }
        var out: [String: SessionRow] = [:]
        for s in sessions {
            if let cur = out[s.date], rank(cur.status) >= rank(s.status) { continue }
            out[s.date] = s
        }
        return out
    }

    /// Resolve one calendar day via the frozen projection algorithm.
    func projection(for dateString: String) -> DayProjection {
        CalendarProjection.project(
            dateString: dateString,
            today: todayString,
            sessionByDate: sessionsByDate,
            schedule: plan?.schedule,
            templateIDs: planTemplateIDs)
    }

    /// Plan day for a template id (agenda exercise targets).
    func dayTemplate(id: String?) -> DayTemplate? {
        guard let id else { return nil }
        return plan?.days.first { $0.id == id }
    }

    /// Logged working + warmup sets for a session (agenda "completed").
    func setsForSession(_ sessionID: String) -> [SetLog] {
        sets.filter { $0.session_id == sessionID && $0.deleted_at == nil }
            .sorted {
                $0.exercise_id == $1.exercise_id
                    ? $0.set_index < $1.set_index
                    : $0.logged_at < $1.logged_at
            }
    }

    private func handle(_ error: Error) {
        if case let APIError.http(code, _) = error, code == 401 {
            auth.invalidate()
        } else {
            loadError = error.localizedDescription
        }
    }
}
