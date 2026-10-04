import SwiftUI

/// Runner strip for a linked iPad Station. It arms the iPad for the current
/// set once rest is over, shows the live count and turns a finished count into
/// the ordinary LOG SET action: a cancellable countdown, or a tap when partial.
struct StationLinkRunnerPanel: View {
    @ObservedObject var sync: SyncModel
    @ObservedObject var link: StationLinkController
    let ex: TemplateExercise

    var body: some View {
        // Rest keeps its deadline after it expires, so re-evaluate each second.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let target = Self.target(sync: sync, ex: ex, now: context.date)
            content(target: target)
                .task(id: target) { link.request(target) }
        }
        .task(id: link.proposal?.eventID) { await runCountdown() }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runner.station")
    }

    static func target(sync: SyncModel, ex: TemplateExercise, now: Date) -> StationLinkTarget? {
        guard sync.running, !sync.finished, !ex.isTimed, !sync.timedActive,
              sync.isFreestyle || sync.runnerSetsDone(ex) < ex.target_sets,
              (sync.restEndDate.map { $0 <= now } ?? true),
              let movement = StationExercise.match(exerciseName: ex.exercise_name,
                                                   modality: ex.exercise_modality) else { return nil }
        return StationLinkTarget(slotID: ex.id, setNumber: sync.currentPhysicalSetNumber,
                                 exercise: movement, exerciseName: ex.exercise_name,
                                 targetReps: ex.target_reps)
    }

    @ViewBuilder
    private func content(target: StationLinkTarget?) -> some View {
        if let proposal = link.proposal {
            proposalView(proposal)
        } else {
            Label(statusText(target: target), systemImage: "ipad.landscape")
                .font(.footnote).foregroundStyle(link.isConnected ? Theme.text : Theme.muted)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                .accessibilityIdentifier("runner.station.status")
        }
    }

    private func statusText(target: StationLinkTarget?) -> String {
        guard link.isConnected else {
            return link.connection == .off ? "iPad Station off" : "Looking for your iPad Station"
        }
        guard target != nil else {
            if sync.restEndDate.map({ $0 > Date() }) == true { return "iPad connected · counts after rest" }
            return "iPad connected · log this set yourself"
        }
        if let progress = link.progress { return "iPad counting · \(countText(progress.count, progress.leftCount, progress.rightCount))" }
        if link.stationState == .cameraOff { return "iPad connected · turn on its camera" }
        return "iPad connected · ready to count"
    }

    private func countText(_ count: Int, _ left: Int?, _ right: Int?) -> String {
        if let left, let right { return "L \(left) · R \(right)" }
        return count == 1 ? "1 rep" : "\(count) reps"
    }

    private func proposalView(_ proposal: StationLinkProposal) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                Text(headline(proposal, now: context.date))
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runner.station.proposal")
            }
            if proposal.partial {
                Text("Tracking was interrupted, so check the count before logging.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button(logTitle(proposal)) {
                    Task { await commit(proposal) }
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(.black)
                .frame(minHeight: 44)
                .accessibilityIdentifier("runner.station.logNow")
                // Edit hands the count to the ordinary rep control and LOG SET.
                Button("Edit") {
                    sync.setReps(proposal.reps)
                    link.finishProposal(proposal.eventID)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("runner.station.edit")
                Button("Not right", role: .cancel) { link.dismissProposal() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("runner.station.dismiss")
            }
            .font(.subheadline)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    private func logTitle(_ proposal: StationLinkProposal) -> String {
        proposal.deadline == nil ? "Log \(proposal.reps)" : "Log now"
    }

    private func headline(_ proposal: StationLinkProposal, now: Date) -> String {
        let counted = proposal.leftCount != nil && proposal.rightCount != nil
            ? "iPad counted \(proposal.reps) (L \(proposal.leftCount ?? 0) · R \(proposal.rightCount ?? 0))"
            : "iPad counted \(proposal.reps) \(proposal.reps == 1 ? "rep" : "reps")"
        guard let deadline = proposal.deadline else { return counted }
        let remaining = max(0, Int(ceil(deadline.timeIntervalSince(now))))
        return "\(counted) · logging in \(remaining)s"
    }

    private func runCountdown() async {
        guard let proposal = link.proposal, let deadline = proposal.deadline else { return }
        let wait = deadline.timeIntervalSinceNow
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        // Edit or Not right removes the proposal; never log either.
        guard !Task.isCancelled, let current = link.proposal,
              current.eventID == proposal.eventID, current.deadline != nil else { return }
        await commit(current)
    }

    /// The count enters the same guarded path as LOG SET: the exact slot and
    /// set it was counted for, or nothing.
    private func commit(_ proposal: StationLinkProposal) async {
        defer { link.finishProposal(proposal.eventID) }
        guard let current = sync.currentExercise,
              StationLinkPolicy.canCommit(proposal, currentSlotID: current.id,
                                          currentSetNumber: sync.currentPhysicalSetNumber,
                                          entryBlocked: sync.isSetEntryBlocked(current)) else { return }
        sync.setReps(proposal.reps)
        await sync.logCurrentSet(expected: current, expectedSetNumber: proposal.setNumber)
    }
}
