import Foundation

/// A trial is explicitly available for an audited catalog ID. A shared profile
/// alone never enables a counter for a new variant. None of these trials can log.
enum StationTrialMode: String, CaseIterable, Decodable, Identifiable {
    case squat, curl, benchPress, plank, wallSit
    var id: String { rawValue }
    var repExercise: StationExercise? { StationExercise(rawValue: rawValue) }
    var holdKind: StationHoldKind? { StationHoldKind(rawValue: rawValue) }
    var title: String { repExercise?.title ?? holdKind!.title }
    var profileID: String {
        switch self {
        case .squat: return "squat"
        case .curl: return "curl"
        case .benchPress: return "horizontal_press"
        case .plank: return "plank"
        case .wallSit: return "wall_sit"
        }
    }
}

struct StationTrackingCatalog {
    struct Profile: Decodable {
        enum Measurement: String, Decodable { case reps, hold }
        let id: String
        let title: String
        let measurement: Measurement
        let cameraView: String
        let definition: String
        let limitation: String
    }
    struct Entry {
        let profile: Profile?
        let trial: StationTrialMode?
        let reason: String?
        var status: String {
            if trial != nil { return "Experimental test available" }
            if let profile { return profile.measurement == .hold ? "Hold timer candidate" : "Rep tracking candidate" }
            return "Manual tracking"
        }
    }
    private struct Document: Decodable {
        struct Group: Decodable {
            let profile: String?
            let trial: StationTrialMode?
            let reason: String?
            let exercises: [String]
        }
        let schemaVersion: Int
        let profiles: [Profile]
        let groups: [Group]
    }
    enum InvalidCatalog: Error { case invalid }
    private let entries: [String: Entry]
    var exerciseIDs: Set<String> { Set(entries.keys) }

    static let bundled: StationTrackingCatalog = {
        guard let url = Bundle.main.url(forResource: "StationTrackingCatalog", withExtension: "json"),
              let data = try? Data(contentsOf: url), let catalog = try? Self(data: data) else {
            // Missing, corrupt or newer metadata never grants tracking support.
            return Self(entries: [:])
        }
        return catalog
    }()

    private init(entries: [String: Entry]) { self.entries = entries }

    init(data: Data) throws {
        let document = try JSONDecoder().decode(Document.self, from: data)
        guard document.schemaVersion == 1,
              Set(document.profiles.map(\.id)).count == document.profiles.count else {
            throw InvalidCatalog.invalid
        }
        let profiles = Dictionary(uniqueKeysWithValues: document.profiles.map { ($0.id, $0) })
        var entries: [String: Entry] = [:]
        for group in document.groups {
            let profile = group.profile.flatMap { profiles[$0] }
            guard !group.exercises.isEmpty,
                  group.profile == nil || profile != nil,
                  profile != nil || !(group.reason ?? "").isEmpty else { throw InvalidCatalog.invalid }
            if let trial = group.trial {
                guard trial.profileID == profile?.id,
                      (trial.holdKind != nil) == (profile?.measurement == .hold) else {
                    throw InvalidCatalog.invalid
                }
            }
            for id in group.exercises {
                guard !id.isEmpty, entries[id] == nil else { throw InvalidCatalog.invalid }
                entries[id] = Entry(profile: profile, trial: group.trial, reason: group.reason)
            }
        }
        self.entries = entries
    }

    func entry(for exerciseID: String) -> Entry {
        entries[exerciseID] ?? Entry(profile: nil, trial: nil,
            reason: "This exercise has not been assessed for camera tracking. Use manual logging or the workout timer.")
    }
}

/// Immutable display/prescription context, with no workout mutation capability.
struct StationExerciseOption: Identifiable {
    let id: String
    let exerciseID: String
    let name: String
    let targetSeconds: Int?

    init(catalog: ExerciseCatalog) {
        id = catalog.id
        exerciseID = catalog.id
        name = catalog.name
        targetSeconds = catalog.modality == "timed" || catalog.modality == "cardio" ? 30 : nil
    }

    init(prescription: TemplateExercise) {
        id = prescription.id
        exerciseID = prescription.exercise_id
        name = prescription.exercise_name
        targetSeconds = prescription.isTimed ? prescription.target_duration_s ?? prescription.target_reps : nil
    }

    func trial(in catalog: StationTrackingCatalog = .bundled) -> StationTrialMode? {
        let entry = catalog.entry(for: exerciseID)
        // A duration override on a rep exercise is not an isometric hold.
        guard (targetSeconds != nil) == (entry.profile?.measurement == .hold) else { return nil }
        if let targetSeconds, !(1...3600).contains(targetSeconds) { return nil }
        return entry.trial
    }
}
