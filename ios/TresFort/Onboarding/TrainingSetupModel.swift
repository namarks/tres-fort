import Foundation
import Combine

struct TrainingProfile: Codable, Equatable {
    var goal = "general_fitness"
    var activities: [String] = []
    var activity_context = ""
    var experience = "new"
    var strength_days = 2
    var session_minutes = 30
    var equipment = "bodyweight"
    var avoid: [String] = []
    var baselines: [Baseline] = []

    /// Selection order and surrounding whitespace are not changes to answers.
    /// Match the server normalization when reconciling an uncertain save.
    var normalized: TrainingProfile {
        var result = self
        result.activities.sort(); result.avoid.sort()
        result.baselines.sort { $0.exercise_id < $1.exercise_id }
        result.activity_context = activity_context.trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    struct Baseline: Codable, Equatable, Identifiable {
        var id: String { exercise_id }
        var exercise_id: String
        var weight: Double
        var unit: String
        var reps: Int
        var effort: String
        var performed_at: Double
    }

    static let baselineExercises: [(id: String, name: String, load: String)] = [
        ("ex_goblet_squat", "Goblet Squat", "One dumbbell, total weight"),
        ("ex_db_rdl", "Dumbbell Romanian Deadlift", "Weight per hand"),
        ("ex_db_press", "Dumbbell Bench Press", "Weight per hand"),
        ("ex_one_arm_db_row", "One-Arm Dumbbell Row", "One dumbbell; reps per side"),
        ("ex_back_squat", "Back Squat", "Total including the bar"),
        ("ex_rdl", "Romanian Deadlift", "Total including the bar"),
        ("ex_bench", "Bench Press", "Total including the bar"),
        ("ex_lat_pulldown", "Lat Pulldown", "Machine weight")
    ]
}

struct TrainingProfileState: Codable, Equatable {
    let profile: TrainingProfile?
    let version: Int
    let updated_at: Double?
}

struct StarterWorkout: Decodable, Identifiable {
    let id: String
    let name: String
    let explanation: String
    let exercises: [Slot]
    struct Slot: Decodable, Identifiable {
        var id: String { exercise_id }
        let exercise_id: String
        let name: String
        let sets: Int
        let reps: Int
        let cues: String
    }
}

struct StarterWorkoutOptions: Decodable {
    let profile_version: Int
    let can_accept: Bool
    let workouts: [StarterWorkout]
}

struct StarterWorkoutReceipt: Codable, Equatable {
    let acknowledged: Bool
    let plan_id: String
    let workout_id: String
    let version: Int
}

protocol TrainingSetupAPI {
    func trainingProfile(jwt: String) async throws -> TrainingProfileState
    func saveTrainingProfile(_ profile: TrainingProfile, version: Int, jwt: String) async throws -> TrainingProfileState
    func starterWorkouts(jwt: String) async throws -> StarterWorkoutOptions
    func acceptStarter(_ id: String, profileVersion: Int, jwt: String) async throws -> StarterWorkoutReceipt
}

extension APIClient: TrainingSetupAPI {
    func trainingProfile(jwt: String) async throws -> TrainingProfileState {
        try await get("api/me/training-profile", jwt: jwt)
    }
    func saveTrainingProfile(_ profile: TrainingProfile, version: Int, jwt: String) async throws -> TrainingProfileState {
        let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(profile))
        return try await put("api/me/training-profile", body: ["profile": encoded, "expected_version": version], jwt: jwt)
    }
    func starterWorkouts(jwt: String) async throws -> StarterWorkoutOptions {
        try await get("api/starter-workouts", jwt: jwt)
    }
    func acceptStarter(_ id: String, profileVersion: Int, jwt: String) async throws -> StarterWorkoutReceipt {
        try await post("api/starter-workouts/\(id)", body: ["profile_version": profileVersion], jwt: jwt)
    }
}

@MainActor
final class TrainingSetupModel: ObservableObject {
    @Published var profile = TrainingProfile() { didSet { persistDraft() } }
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var options: StarterWorkoutOptions?
    @Published private(set) var receipt: StarterWorkoutReceipt?
    @Published private(set) var hasConflict = false
    @Published private(set) var hasUnreadableDraft = false
    private(set) var version = 0
    private var restoring = false
    private var generation = 0
    private var acceptance: Acceptance?
    private let accountID: String?
    private let epoch: UInt64
    private unowned let auth: AuthModel
    private let api: any TrainingSetupAPI
    private let defaults: LocalPersistence

    private struct Acceptance: Codable {
        let id: String
        let profileVersion: Int
    }
    private struct Draft: Codable {
        let profile: TrainingProfile
        let version: Int
        let acceptance: Acceptance?
    }

    init(auth: AuthModel, api: any TrainingSetupAPI = APIClient(), defaults: LocalPersistence) {
        self.auth = auth; self.api = api; self.defaults = defaults
        accountID = auth.userID; epoch = auth.featureSessionEpoch
    }
    private var current: Bool { auth.isCurrentFeatureSession(accountID: accountID, epoch: epoch) }
    private var draftKey: String? { accountID.map { AccountLocalState.trainingProfileDraftKey(userID: $0) } }
    var hasUncertainAcceptance: Bool { acceptance != nil && receipt == nil }

    func cancel() { generation += 1; ready = false }

    private func persistDraft() {
        guard !restoring, ready, current, let draftKey else { return }
        guard let bytes = try? JSONEncoder().encode(Draft(profile: profile, version: version, acceptance: acceptance)),
              defaults.set(bytes, forKey: draftKey) else {
            error = "Your answers couldn’t be saved on this device. Keep this screen open and try again."
            return
        }
    }

    func load(discardDraft: Bool = false) async {
        guard current, !busy, let jwt = auth.featureJWT else { return }
        let ticket = generation
        busy = true; error = nil; hasUnreadableDraft = false
        defer { if ticket == generation { busy = false } }
        do {
            let saved = try await api.trainingProfile(jwt: jwt)
            guard current, ticket == generation else { return }
            var draft: Draft?
            if let draftKey, !discardDraft, let bytes = defaults.data(forKey: draftKey) {
                do { draft = try JSONDecoder().decode(Draft.self, from: bytes) }
                catch {
                    ready = false; hasUnreadableDraft = true
                    self.error = "The unfinished answers on this device couldn’t be read. Use your saved profile to continue, or skip setup."
                    return
                }
            }
            if let draftKey, defaults.hasFailure(forKey: draftKey) { throw APIError.decoding("Protected draft unavailable") }
            restoring = true
            profile = draft?.profile ?? saved.profile ?? TrainingProfile()
            version = draft?.version ?? saved.version
            if let remote = saved.profile, profile.normalized == remote.normalized {
                // The server may have committed a save whose reply was lost.
                // Matching answers confirm it; future edits must use its version.
                profile = remote
                version = saved.version
            }
            acceptance = draft?.acceptance
            restoring = false; ready = true
            hasConflict = draft != nil && version != saved.version && profile != saved.profile
            if hasConflict { error = "Your saved profile changed elsewhere. Reload the saved profile before making new changes." }
            if discardDraft { acceptance = nil }
            persistDraft()
            if let acceptance {
                // Resolve the same acceptance after relaunch; never choose a
                // different recipe while an earlier response is uncertain.
                let result = try await api.acceptStarter(acceptance.id, profileVersion: acceptance.profileVersion, jwt: jwt)
                auth.noteAccountStatePersisted(for: accountID)
                guard current, ticket == generation else { return }
                receipt = result
                self.acceptance = nil
                persistDraft()
            }
        } catch {
            guard current, ticket == generation else { return }
            if (error as? APIError)?.httpStatus == 409 {
                // The server checks the matching durable receipt first. A
                // conflict proves this acceptance was not committed, so it
                // is safe to retire the pending intent and reload.
                acceptance = nil; hasConflict = true; persistDraft()
                self.error = "Your training changed. Reload your saved profile and check your workout library."
            } else {
                self.error = "Couldn’t load your training setup. Your existing workouts are safe. Try again, or finish setup later."
            }
        }
    }

    func save(showStarters: Bool) async -> Bool {
        guard current, ready, !busy, !hasConflict, acceptance == nil, let jwt = auth.featureJWT else { return false }
        let ticket = generation
        busy = true; error = nil
        defer { if ticket == generation { busy = false } }
        do {
            let saved = try await api.saveTrainingProfile(profile, version: version, jwt: jwt)
            guard current, ticket == generation else { return false }
            restoring = true; profile = saved.profile ?? profile; version = saved.version; restoring = false
            persistDraft()
            if showStarters {
                // Saving was acknowledged already. A preview-read failure
                // remains distinct from failure to save the questionnaire.
                let received = try await api.starterWorkouts(jwt: jwt)
                guard current, ticket == generation else { return false }
                options = received
                guard options?.profile_version == version else {
                    options = nil; hasConflict = true; error = "Your profile changed. Reload it to review matching workouts."; return false
                }
            }
            return true
        } catch {
            guard current, ticket == generation else { return false }
            hasConflict = (error as? APIError)?.httpStatus == 409
            self.error = hasConflict ? "Your profile changed elsewhere. Reload the saved profile to continue."
                : "Couldn’t finish setup. Your answers are kept here; try again when connected."
            return false
        }
    }

    func accept(_ starter: StarterWorkout) async {
        guard current, !busy, ready, let jwt = auth.featureJWT, let options, options.can_accept,
              options.profile_version == version else { return }
        if let acceptance, acceptance.id != starter.id { return }
        acceptance = acceptance ?? Acceptance(id: starter.id, profileVersion: version)
        persistDraft()
        guard let draftKey, !defaults.hasFailure(forKey: draftKey), let acceptance else { return }
        let ticket = generation
        busy = true; error = nil
        defer { if ticket == generation { busy = false } }
        do {
            let result = try await api.acceptStarter(acceptance.id, profileVersion: acceptance.profileVersion, jwt: jwt)
            auth.noteAccountStatePersisted(for: accountID)
            guard current, ticket == generation else { return }
            receipt = result
            self.acceptance = nil
            persistDraft()
        } catch {
            guard current, ticket == generation else { return }
            if (error as? APIError)?.httpStatus == 409 {
                self.acceptance = nil; persistDraft()
                self.error = "Your training has changed. Check your workout library before continuing."
                hasConflict = true
            } else {
                self.error = "Couldn’t confirm your workout was saved. Retry checks the same workout without creating a duplicate."
            }
        }
    }
}
