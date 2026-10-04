import CryptoKit
import Foundation

/// The iPhone runner is the only workout controller. A linked iPad Station is a
/// sensor: it counts the set the iPhone arms and reports a finished count. The
/// iPad never receives a SyncModel, outbox or API client; only the iPhone logs.
enum StationLink {
    /// Bonjour service type (at most 15 characters). Info.plist lists the
    /// matching `_tresfort-stn._tcp` / `_udp` entries for local network access.
    static let serviceType = "tresfort-stn"
    static let protocolVersion = 1
    /// Seconds the count must hold steady, outside a rep, before the iPad
    /// reports the set finished. Target reps never end a set on their own.
    static let settleSeconds: TimeInterval = 4
    static let enabledDefaultsKey = "stationLinkEnabled"

    /// Discovery advertises only a one-way account tag, never the account ID.
    /// Devices pair only when both are signed in to the same account.
    static func accountTag(for accountID: String) -> String {
        let digest = SHA256.hash(data: Data("tres-fort-station-link:\(accountID)".utf8))
        return digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }
}

extension StationExercise: Codable {
    /// Maps a workout slot to a movement the Station can count. Anything else
    /// stays a manual set: a lookalike name must not borrow another counter.
    static func match(exerciseName: String, modality: String? = nil) -> StationExercise? {
        let name = exerciseName.lowercased()
        if modality == "timed" || modality == "cardio" { return nil }
        let excluded = ["split", "jump", "pistol", "hack", "leg press", "leg curl", "hamstring",
                        "nordic", "wrist"]
        if excluded.contains(where: { name.contains($0) }) { return nil }
        if name.contains("bench press") { return .benchPress }
        if name.contains("squat") { return .squat }
        if name.contains("curl") { return .curl }
        return nil
    }
}

/// One armed set. A new ID is minted for every distinct slot and set number,
/// so a late count from an earlier set can never complete the current one.
struct StationLinkArm: Codable, Equatable {
    let armID: UUID
    let slotID: String
    let setNumber: Int
    let exercise: StationExercise
    let exerciseName: String
    let targetReps: Int
}

struct StationLinkProgress: Codable, Equatable {
    let armID: UUID
    let count: Int
    let leftCount: Int?
    let rightCount: Int?
    let status: String
}

struct StationLinkCompletion: Codable, Equatable {
    let armID: UUID
    /// Stable identity for this observation; the iPhone acts on it once.
    let eventID: UUID
    let reps: Int
    let leftCount: Int?
    let rightCount: Int?
    /// Tracking was interrupted, so the count covers only what was seen.
    let partial: Bool
}

enum StationLinkStationState: String, Codable, Equatable {
    case ready, cameraOff, counting, stopped
}

enum StationLinkMessage: Codable, Equatable {
    case arm(StationLinkArm)
    case disarm(armID: UUID)
    case progress(StationLinkProgress)
    case completion(StationLinkCompletion)
    case station(StationLinkStationState, armID: UUID?)

    func encoded() throws -> Data {
        try JSONEncoder().encode(StationLinkEnvelope(version: StationLink.protocolVersion, message: self))
    }

    static func decode(_ data: Data) -> StationLinkMessage? {
        guard let envelope = try? JSONDecoder().decode(StationLinkEnvelope.self, from: data),
              envelope.version == StationLink.protocolVersion else { return nil }
        return envelope.message
    }
}

private struct StationLinkEnvelope: Codable {
    let version: Int
    let message: StationLinkMessage
}

/// The set the iPhone runner would like counted right now, or nil when the
/// runner is resting, timed, complete or on a movement the Station can't count.
struct StationLinkTarget: Equatable {
    let slotID: String
    let setNumber: Int
    let exercise: StationExercise
    let exerciseName: String
    let targetReps: Int
}

/// A finished count on the iPhone. A complete count logs at once (the owner
/// chose instant logging with undo); a partial count never auto-logs.
struct StationLinkProposal: Equatable, Identifiable {
    let eventID: UUID
    let slotID: String
    let setNumber: Int
    let exerciseName: String
    let reps: Int
    let leftCount: Int?
    let rightCount: Int?
    let partial: Bool
    let logsAutomatically: Bool
    var id: UUID { eventID }
}

/// The last set a Station count logged, kept so the member can undo it.
struct StationLinkLoggedSet: Equatable {
    let setID: String
    let slotID: String
    let setNumber: Int
    let reps: Int
}

enum StationLinkPolicy {
    /// Accept a completion only for the currently armed set, only once, and
    /// only with a usable rep count.
    static func proposal(for completion: StationLinkCompletion, arm: StationLinkArm?,
                         seenEvents: Set<UUID>) -> StationLinkProposal? {
        guard let arm, completion.armID == arm.armID, !seenEvents.contains(completion.eventID),
              completion.reps > 0, completion.reps < 1000 else { return nil }
        return StationLinkProposal(
            eventID: completion.eventID, slotID: arm.slotID, setNumber: arm.setNumber,
            exerciseName: arm.exerciseName, reps: completion.reps,
            leftCount: completion.leftCount, rightCount: completion.rightCount,
            partial: completion.partial, logsAutomatically: !completion.partial)
    }

    /// A proposal may log only into the exact slot and set it was counted for.
    static func canCommit(_ proposal: StationLinkProposal, currentSlotID: String?,
                          currentSetNumber: Int, entryBlocked: Bool) -> Bool {
        proposal.slotID == currentSlotID && proposal.setNumber == currentSetNumber && !entryBlocked
    }

    /// Whether an existing arm still describes the requested target.
    static func arm(_ arm: StationLinkArm?, matches target: StationLinkTarget?) -> Bool {
        guard let arm, let target else { return arm == nil && target == nil }
        return arm.slotID == target.slotID && arm.setNumber == target.setNumber
            && arm.exercise == target.exercise && arm.targetReps == target.targetReps
    }
}

/// Decides on the iPad when an armed set is over: at least one rep, then no new
/// rep for `settleSeconds` while not mid-movement. Reaching the target count
/// alone never finishes a set, so extra reps still count.
struct StationSetEndDetector {
    private(set) var lastCount = 0
    private(set) var hasFinished = false
    private var lastChange: TimeInterval?

    mutating func reset() { self = Self() }

    /// Returns true exactly once, when the set is judged finished.
    mutating func observe(count: Int, status: StationTrackingStatus, at time: TimeInterval) -> Bool {
        guard !hasFinished, time.isFinite else { return false }
        if lastChange == nil || count != lastCount {
            lastCount = count
            lastChange = time
            return false
        }
        guard count > 0, status != .moving, status != .multiplePeople,
              let lastChange, time - lastChange >= StationLink.settleSeconds else { return false }
        hasFinished = true
        return true
    }
}
