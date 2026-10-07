import Foundation
import CryptoKit

/// Shared coordination never grants one phone authority over the other account.
enum PartnerLane: String, Codable, CaseIterable { case host, partner }

struct PartnerInvitation: Codable, Equatable {
    let id: UUID
    let secret: Data
    let expiresAt: Date

    init(id: UUID, now: Date = Date()) {
        self.id = id
        secret = StationLink.newNonce()
        expiresAt = now.addingTimeInterval(120)
    }
    var code: String {
        let data = (try? JSONEncoder().encode(self)) ?? Data()
        return "tresfort-partner:" + data.base64EncodedString()
    }
    static func parse(_ code: String, now: Date = Date()) -> Self? {
        guard code.utf8.count < 2048, code.hasPrefix("tresfort-partner:"),
              let data = Data(base64Encoded: String(code.dropFirst("tresfort-partner:".count))),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.secret.count == 32, value.expiresAt > now,
              value.expiresAt.timeIntervalSince(now) <= 125 else { return nil }
        return value
    }
    func fingerprint(accountID: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data("partner-account:\(accountID)".utf8),
                                             using: SymmetricKey(data: secret)))
    }
}

struct PartnerStep: Codable, Equatable, Identifiable {
    let slotID: String
    let set: Int
    let name: String
    let restSeconds: Int
    var id: String { "\(slotID):\(set)" }

    static func sequence(_ workout: Workout) -> [PartnerStep] {
        let slots = workout.exercises.sorted { $0.order_index < $1.order_index }
        var steps: [PartnerStep] = [], index = 0
        while index < slots.count {
            let first = slots[index]
            var members = [first]
            if let group = first.group_id {
                members = Array(slots[index...].prefix { $0.group_id == group })
            }
            for round in 1...max(1, min(100, first.target_sets)) {
                for (memberIndex, slot) in members.enumerated() {
                    let rest = first.group_id == nil ? slot.rest_seconds
                        : memberIndex == members.count - 1 ? slot.group_rest_seconds ?? slot.rest_seconds
                        : slot.group_transition_seconds ?? 0
                    steps.append(.init(slotID: slot.id, set: round, name: slot.exercise_name, restSeconds: rest))
                }
            }
            index += members.count
        }
        if let last = steps.popLast() {
            steps.append(.init(slotID: last.slotID, set: last.set, name: last.name, restSeconds: 0))
        }
        return steps
    }
}

struct PartnerOffer: Codable, Equatable {
    let id: UUID
    let hostName: String
    let planID: String
    let planVersion: Int
    let workout: Workout
    var steps: [PartnerStep] { PartnerStep.sequence(workout) }
    var isValid: Bool {
        !hostName.isEmpty && hostName.count <= 80 && planVersion > 0
            && UUID(uuidString: planID) != nil && UUID(uuidString: workout.id) != nil
            && !workout.exercises.isEmpty && workout.exercises.count <= 50
            && Set(workout.exercises.map(\.id)).count == workout.exercises.count
            && workout.exercises.allSatisfy {
                UUID(uuidString: $0.id) != nil && (1...100).contains($0.target_sets)
                    && $0.target_reps > 0 && $0.rest_seconds >= 0
            }
    }
}

struct PartnerSlot: Codable, Equatable, Identifiable {
    let id: String
    let exercise_id: String
    let order_index: Int
    let target_sets: Int
    let target_reps: Int
    let target_reps_max: Int?
    let target_rpe: Double?
    let rest_seconds: Int
    var target_weight: Double?
    var target_weight_unit: String
    let target_duration_s: Int?
    let progression: String?
    let cues: String?
    let is_warmup: Int
    let group_id: String?
    let group_rest_seconds: Int?
    let group_transition_seconds: Int?

    init(_ slot: TemplateExercise, id: String, index: Int, groupID: String?) {
        self.id = id; exercise_id = slot.exercise_id; order_index = index
        target_sets = slot.target_sets; target_reps = slot.target_reps; target_reps_max = slot.target_reps_max
        target_rpe = slot.target_rpe; rest_seconds = slot.rest_seconds; target_weight = slot.target_weight
        target_weight_unit = slot.targetWeightUnit.rawValue; target_duration_s = slot.target_duration_s
        progression = slot.progression; cues = slot.cues; is_warmup = slot.is_warmup ?? 0
        group_id = groupID; group_rest_seconds = slot.group_rest_seconds
        group_transition_seconds = slot.group_transition_seconds
    }
}

struct PartnerCopyRequest: Codable, Equatable {
    let workout_id: String
    let name: String
    let expected_plan_id: String?
    let expected_version: Int
    var slots: [PartnerSlot]
}
struct PartnerCopyReceipt: Codable, Equatable { let workout_id: String; let plan_id: String; let version: Int }
struct PartnerStartRequest: Codable, Equatable {
    let id: String
    let session_id: String
    let partner_workout_id: String
    let date: String
    let workout_id: String
    let expected_plan_id: String
    let expected_version: Int
    let expected_attempt: Int
}
struct PartnerSessionResponse: Decodable { let session: SessionRow }

struct PartnerDisplaySlot: Codable, Equatable {
    let hostSlotID: String
    let weight: Double?
    let unit: String
    let reps: Int
}
struct PartnerLaneSnapshot: Codable, Equatable {
    var logged: Set<String> = []
    var skipped: Set<String> = []
    var closed = false
    var display: PartnerDisplaySlot? = nil
}
struct PartnerSharedState: Codable, Equatable {
    var revision: UInt64
    let stepIndex: Int
    let restUntil: Date?
    let skipped: Set<String>
    let host: PartnerLaneSnapshot
    let partner: PartnerLaneSnapshot
    let hostConnected: Bool
    let partnerConnected: Bool
    func snapshot(_ lane: PartnerLane) -> PartnerLaneSnapshot { lane == .host ? host : partner }
}

/// Pure shared-step rules. The iPad keeps only ephemeral state; each phone's
/// durable snapshot owns its own logged sets, including after reconnect/Undo.
struct PartnerCoordinator {
    let steps: [PartnerStep]
    private(set) var lanes: [PartnerLane: PartnerLaneSnapshot] = [.host: .init(), .partner: .init()]
    private(set) var connected: Set<PartnerLane> = []
    private(set) var skipped: Set<String> = []
    private(set) var released = -1
    private(set) var highestReleased = -1
    private(set) var restUntil: Date?
    private(set) var revision: UInt64 = 0
    private var restingStep: Int?

    var state: PartnerSharedState {
        .init(revision: revision, stepIndex: min(released + 1, steps.count), restUntil: restUntil,
              skipped: skipped, host: lanes[.host]!, partner: lanes[.partner]!,
              hostConnected: connected.contains(.host), partnerConnected: connected.contains(.partner))
    }
    mutating func receive(_ snapshot: PartnerLaneSnapshot, from lane: PartnerLane, now: Date) {
        guard lanes[lane]?.closed != true else { return }
        let valid = Set(steps.map(\.id))
        let old = lanes[lane]?.logged ?? []
        // An Undo clears any shared skip on that step too.
        skipped.subtract(old.subtracting(snapshot.logged))
        // Shared skips belong to this iPad. A phone can echo an older state
        // after an Undo; that echo must never resurrect the cleared skip.
        lanes[lane] = .init(logged: snapshot.logged.intersection(valid), skipped: [], closed: snapshot.closed,
                             display: snapshot.display.flatMap { value in steps.contains(where: { $0.slotID == value.hostSlotID }) ? value : nil })
        connected.insert(lane)
        reconcile(now: now)
    }
    mutating func disconnect(_ lane: PartnerLane, now: Date) {
        connected.remove(lane); reconcile(now: now)
    }
    mutating func skipCurrent(now: Date) {
        let index = released + 1
        guard steps.indices.contains(index) else { return }
        skipped.insert(steps[index].id); reconcile(now: now)
    }
    mutating func skipRest(now: Date) {
        guard restUntil != nil else { return }
        restUntil = now; reconcile(now: now)
    }
    mutating func close(_ lane: PartnerLane, now: Date) {
        lanes[lane]?.closed = true; reconcile(now: now)
    }
    mutating func reconcile(now: Date) {
        let active = PartnerLane.allCases.filter { lanes[$0]?.closed != true }
        guard !active.isEmpty else { released = steps.count - 1; restUntil = nil; revision &+= 1; return }
        func done(_ index: Int) -> Bool {
            skipped.contains(steps[index].id) || active.allSatisfy { lanes[$0]!.logged.contains(steps[index].id) }
        }
        var complete = -1
        while complete + 1 < steps.count, done(complete + 1) { complete += 1 }
        if complete <= released {
            released = complete; restUntil = nil; restingStep = nil
        }
        // Earlier rests already elapsed before an Undo; don't make the pair
        // repeat those rests while catching back up to the released frontier.
        while released < min(complete, highestReleased) { released += 1 }
        while active.allSatisfy({ connected.contains($0) }), released + 1 < steps.count, done(released + 1) {
            let index = released + 1
            if restingStep != index {
                restingStep = index; restUntil = now.addingTimeInterval(TimeInterval(steps[index].restSeconds))
            }
            guard let end = restUntil, end <= now else { break }
            released = index; highestReleased = max(highestReleased, released)
            restUntil = nil; restingStep = nil
        }
        revision &+= 1
    }
}

struct PartnerPacket: Codable, Equatable { let id: UUID; let message: PartnerMessage }
enum PartnerMessage: Codable, Equatable {
    case requestSetup
    case hostSetup(PartnerOffer, resumeKey: Data)
    case join(name: String, fingerprint: Data)
    case accept(PartnerOffer, resumeKey: Data)
    case resumeStored
    case ready(name: String, slots: [PartnerDisplaySlot])
    case start(round: UUID)
    case started(round: UUID)
    case failed(String)
    case state(PartnerSharedState)
    case snapshot(PartnerLaneSnapshot)
    case skip(stepID: String)
    case skipRest(stepID: String)
    case leave
    case cancel
}

extension APIClient {
    func partnerPost<Request: Encodable, Response: Decodable>(_ path: String, body: Request, jwt: String) async throws -> Response {
        let data = try JSONEncoder().encode(body)
        // Synthesized Encodable omits optional nils, but the planless contract
        // requires explicit null. Reconstitute only this one nullable field.
        var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        if let copy = body as? PartnerCopyRequest, copy.expected_plan_id == nil { object["expected_plan_id"] = NSNull() }
        if var slots = object["slots"] as? [[String: Any]] {
            for index in slots.indices where slots[index]["progression"] == nil { slots[index]["progression"] = NSNull() }
            object["slots"] = slots
        }
        return try await post(path, body: object, jwt: jwt)
    }
}

struct PartnerRunnerControl: Equatable {
    let slotID: String?
    let set: Int
    let canLog: Bool
    let restUntil: Date?
    let complete: Bool
}

/// A terminal setup decision also fences acknowledgements already in flight.
struct PartnerStartBarrier {
    let round: UUID
    private(set) var acknowledged: Set<PartnerLane> = []
    private(set) var cancelled = false
    var active: Bool { !cancelled && acknowledged.count == 2 }
    mutating func acknowledge(_ lane: PartnerLane, round: UUID) -> Bool {
        guard !cancelled, round == self.round else { return false }
        acknowledged.insert(lane)
        return active
    }
    mutating func cancelSetup() { cancelled = true }
}
