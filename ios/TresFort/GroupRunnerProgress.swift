import Foundation

/// A round is derived from durable physical-set identities, never advanced by
/// a transport callback. Replacing a queued UUID with its ACK is a no-op here.
struct GroupRunnerProgress: Codable, Equatable {
    struct Member: Codable, Equatable {
        let id: String
        let target: Int
        let completedIDs: Set<String>
        let skipped: Bool
    }
    let id: String
    let members: [Member]

    var executable: [Member] { members.filter { !$0.skipped } }
    var nextMemberID: String? { nextMemberID(completing: nil) }

    /// Preview the same scheduling decision a successful local commit makes.
    /// Adjust the count without inventing a durable set ID. Logging also
    /// re-enables a manually revisited skipped member, as the live runner does.
    /// A complete or missing member cannot produce a new set.
    func nextMemberID(afterCompleting memberID: String) -> String? {
        guard let member = members.first(where: { $0.id == memberID }),
              member.completedIDs.count < member.target else { return nil }
        return nextMemberID(completing: memberID)
    }

    private func nextMemberID(completing memberID: String?) -> String? {
        let candidates = members.filter { !$0.skipped || $0.id == memberID }
        let incomplete = candidates.map { member in
            (member: member, count: member.completedIDs.count + (member.id == memberID ? 1 : 0))
        }.filter { $0.count < $0.member.target }
        guard let minimum = incomplete.map(\.count).min() else { return nil }
        return incomplete.first { $0.count == minimum }?.member.id
    }
    var completedRounds: Int { executable.map { min($0.completedIDs.count, $0.target) }.min() ?? 0 }
    var round: Int { completedRounds + 1 }
}
