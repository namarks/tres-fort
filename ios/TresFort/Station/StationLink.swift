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
    /// Matches the server's `STATION_LINK_KEY_VERSION`.
    static let keyVersion = 1
    /// Seconds the count must hold steady, outside a rep, before the iPad
    /// reports the set finished. Target reps never end a set on their own.
    static let settleSeconds: TimeInterval = 4
    static let enabledDefaultsKey = "stationLinkEnabled"

    /// Discovery filters peers by a tag derived from the account's link key.
    /// The tag is public, so it is only a filter: a peer must still prove it
    /// holds the key before any count or arm crosses the link.
    static func discoveryTag(key: Data) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data("tres-fort:station-link:discovery".utf8),
                                                  using: SymmetricKey(data: key))
        return Data(mac).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func newNonce() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Mutual challenge-response: the responder's role and both nonces are
    /// bound, so a proof can be neither replayed nor reflected back.
    static func proof(key: Data, responderRole: String, challengerNonce: Data, responderNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: proofMessage(responderRole, challengerNonce, responderNonce), using: SymmetricKey(data: key)))
    }

    static func verify(_ proof: Data, key: Data, responderRole: String,
                       challengerNonce: Data, responderNonce: Data) -> Bool {
        guard challengerNonce.count == 32, responderNonce.count == 32 else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            proof, authenticating: proofMessage(responderRole, challengerNonce, responderNonce),
            using: SymmetricKey(data: key))
    }

    private static func proofMessage(_ role: String, _ challenger: Data, _ responder: Data) -> Data {
        Data("tres-fort:station-link:proof:\(role):".utf8) + challenger + responder
    }

    /// A key for one authenticated connection, bound to both of its nonces.
    /// A relay can pass the challenge along, but without the account key it
    /// cannot derive this, so it can forward sealed messages and nothing more.
    static func sessionKey(key: Data, controllerNonce: Data, stationNonce: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(
            for: Data("tres-fort:station-link:session:".utf8) + controllerNonce + stationNonce,
            using: SymmetricKey(data: key)))
    }

    /// Encrypts an app message for the authenticated peer (ChaCha20-Poly1305
    /// under the session key). The sender's role and a per-direction counter
    /// that starts at 1 are authenticated and fix the nonce, so a relay can
    /// neither read, forge, reflect nor replay a message.
    static func seal(_ message: StationLinkMessage, sessionKey: Data, senderRole: String,
                     counter: UInt64) -> Data? {
        guard let body = try? message.encoded(),
              let nonce = try? ChaChaPoly.Nonce(data: sealNonce(senderRole, counter)),
              let box = try? ChaChaPoly.seal(body, using: SymmetricKey(data: sessionKey), nonce: nonce,
                                             authenticating: sealedContext(senderRole, counter)) else { return nil }
        return try? JSONEncoder().encode(StationLinkSealedFrame(counter: counter, sealed: box.combined))
    }

    /// Opens a sealed message only when it authenticates for the expected
    /// sender and its counter is newer than the last one accepted.
    static func open(_ data: Data, sessionKey: Data, senderRole: String,
                     after lastCounter: UInt64) -> (message: StationLinkMessage, counter: UInt64)? {
        guard let frame = try? JSONDecoder().decode(StationLinkSealedFrame.self, from: data),
              frame.counter > lastCounter,
              let box = try? ChaChaPoly.SealedBox(combined: frame.sealed),
              box.nonce.withUnsafeBytes({ Data($0) }) == sealNonce(senderRole, frame.counter),
              let body = try? ChaChaPoly.open(box, using: SymmetricKey(data: sessionKey),
                                              authenticating: sealedContext(senderRole, frame.counter)),
              let message = StationLinkMessage.decode(body) else { return nil }
        return (message, frame.counter)
    }

    private static func counterBytes(_ counter: UInt64) -> Data {
        withUnsafeBytes(of: counter.bigEndian) { Data($0) }
    }

    /// Unique per direction and counter under a key used for one connection.
    private static func sealNonce(_ role: String, _ counter: UInt64) -> Data {
        Data(SHA256.hash(data: Data("tres-fort:station-link:nonce:\(role)".utf8)).prefix(4))
            + counterBytes(counter)
    }

    private static func sealedContext(_ role: String, _ counter: UInt64) -> Data {
        Data("tres-fort:station-link:message:\(role):".utf8) + counterBytes(counter)
    }
}

private struct StationLinkSealedFrame: Codable {
    let counter: UInt64
    let sealed: Data
}

extension StationExercise: Codable {
    /// Maps a workout slot to a movement the Station can count. Anything else
    /// stays a manual set: a lookalike name must not borrow another counter.
    /// One-side movements prescribe reps per side, which one count can't
    /// cover, so they stay manual too.
    static func match(exerciseName: String, modality: String? = nil,
                      unilateral: Bool = false) -> StationExercise? {
        let name = exerciseName.lowercased()
        if unilateral || modality == "timed" || modality == "cardio" { return nil }
        let excluded = ["split", "jump", "pistol", "hack", "leg press", "leg curl", "hamstring",
                        "nordic", "wrist", "single", "one-arm", "one arm", "one-leg", "one leg",
                        "skater", "cossack", "lateral", "alternating", "jefferson"]
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
    /// Link authentication, handled by the transport and never delivered.
    case challenge(Data)
    case proof(Data)

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
    private var lastSides: [Int?] = [nil, nil]
    private var lastChange: TimeInterval?

    mutating func reset() { self = Self() }

    /// Returns true exactly once, when the set is judged finished. A rep on
    /// either side counts as a change, so a trailing arm keeps the set open.
    mutating func observe(count: Int, leftCount: Int? = nil, rightCount: Int? = nil,
                          status: StationTrackingStatus, at time: TimeInterval) -> Bool {
        guard !hasFinished, time.isFinite else { return false }
        let sides = [leftCount, rightCount]
        if lastChange == nil || count != lastCount || sides != lastSides {
            lastCount = count
            lastSides = sides
            lastChange = time
            return false
        }
        guard count > 0, status != .moving, status != .multiplePeople,
              let lastChange, time - lastChange >= StationLink.settleSeconds else { return false }
        hasFinished = true
        return true
    }
}
