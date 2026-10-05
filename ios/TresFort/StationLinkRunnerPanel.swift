import SwiftUI

/// Runner strip for a linked iPad Station. It arms the iPad for the current
/// set once rest is over, shows the live count and turns a finished count into
/// the ordinary LOG SET action at once (with Undo), or on a tap when partial.
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
        .task(id: link.proposal?.eventID) { await logAutomatically() }
        // Undo belongs to the iPad's set only until another set is logged.
        .onChange(of: sync.lastRunnerSetID) { _, setID in
            if let logged = link.lastLogged, logged.setID != setID { link.clearLogged() }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runner.station")
    }

    static func target(sync: SyncModel, ex: TemplateExercise, now: Date) -> StationLinkTarget? {
        // A blocked slot disarms; unblocking mints a fresh arm for the set.
        guard sync.running, !sync.finished, !ex.isTimed, !sync.timedActive, !sync.isSetEntryBlocked(ex),
              sync.isFreestyle || sync.runnerSetsDone(ex) < ex.target_sets,
              (sync.restEndDate.map { $0 <= now } ?? true),
              let movement = StationExercise.match(exerciseName: ex.exercise_name,
                                                   modality: ex.exercise_modality,
                                                   unilateral: ex.isUnilateral) else { return nil }
        return StationLinkTarget(slotID: ex.id, setNumber: sync.currentPhysicalSetNumber,
                                 exercise: movement, exerciseName: ex.exercise_name,
                                 targetReps: ex.target_reps)
    }

    @ViewBuilder
    private func content(target: StationLinkTarget?) -> some View {
        if let proposal = link.proposal, !proposal.logsAutomatically {
            proposalView(proposal)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                if let logged = link.lastLogged { StationLinkUndoRow(sync: sync, link: link, logged: logged) }
                Label(statusText(target: target), systemImage: "ipad.landscape")
                    .font(.footnote).foregroundStyle(link.isConnected ? Theme.text : Theme.muted)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    .accessibilityIdentifier("runner.station.status")
            }
        }
    }

    private func statusText(target: StationLinkTarget?) -> String {
        guard link.isConnected else {
            if link.needsKey { return "Go online once to set up iPad Station" }
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
            Text(headline(proposal))
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("runner.station.proposal")
            if proposal.partial {
                Text("Tracking was interrupted, so check the count before logging.")
                    .font(.caption).foregroundStyle(.orange)
            } else if proposal.sidesDiffer {
                Text("Your arms counted differently, so check the count before logging.")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Text("The set wasn't saved. Try again or edit it.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button("Log \(proposal.reps)") {
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

    private func headline(_ proposal: StationLinkProposal) -> String {
        if let left = proposal.leftCount, let right = proposal.rightCount {
            return "iPad counted \(proposal.reps) (L \(left) · R \(right))"
        }
        return "iPad counted \(proposal.reps) \(proposal.reps == 1 ? "rep" : "reps")"
    }

    private func logAutomatically() async {
        guard let proposal = link.proposal, proposal.logsAutomatically else { return }
        await commit(proposal)
    }

    /// The count enters the same guarded path as LOG SET: the exact slot and
    /// set it was counted for, or nothing.
    private func commit(_ proposal: StationLinkProposal) async {
        guard let current = sync.currentExercise,
              StationLinkPolicy.canCommit(proposal, currentSlotID: current.id,
                                          currentSetNumber: sync.currentPhysicalSetNumber,
                                          currentExerciseName: current.exercise_name,
                                          entryBlocked: sync.isSetEntryBlocked(current)) else {
            link.finishProposal(proposal.eventID)
            return
        }
        let previous = sync.lastRunnerSetID
        let previousReps = sync.reps
        sync.setReps(proposal.reps)
        await sync.logCurrentSet(expected: current, expectedSetNumber: proposal.setNumber)
        guard let setID = sync.lastRunnerSetID, setID != previous else {
            // The set wasn't saved: keep the count on screen to try again, and
            // give the member's own rep entry back to LOG SET.
            if sync.currentExercise?.id == current.id, sync.currentPhysicalSetNumber == proposal.setNumber {
                sync.setReps(previousReps)
            }
            link.holdProposal(proposal.eventID)
            return
        }
        link.finishProposal(proposal.eventID)
        link.recordLogged(StationLinkLoggedSet(setID: setID, slotID: proposal.slotID,
                                               setNumber: proposal.setNumber, reps: proposal.reps))
    }
}

/// "iPad logged 8 reps · Undo", in the runner and in final review. Undo
/// removes the set through the ordinary correction path, ends rest and returns
/// to that slot so the iPad counts the set again.
struct StationLinkUndoRow: View {
    @ObservedObject var sync: SyncModel
    @ObservedObject var link: StationLinkController
    let logged: StationLinkLoggedSet

    var body: some View {
        HStack {
            Text("iPad logged \(logged.reps) \(logged.reps == 1 ? "rep" : "reps")")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                .accessibilityIdentifier("runner.station.logged")
            Spacer()
            Button("Undo") { Task { await undo() } }
                .font(.subheadline.weight(.semibold))
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Undo set logged from iPad")
                .accessibilityIdentifier("runner.station.undo")
        }
    }

    private func undo() async {
        let queued: Bool
        if let set = sync.sets.first(where: { $0.id == logged.setID && $0.deleted_at == nil }) {
            queued = sync.enqueueCorrection(set: set, values: nil)
        } else if let pending = sync.setOutbox.pending.first(where: { $0.id == logged.setID }) {
            queued = sync.enqueueCorrection(pending: pending, values: nil)
        } else {
            link.clearLogged() // already gone
            return
        }
        // Undo stays offered until the deletion is safely queued.
        guard queued else { return }
        link.clearLogged()
        if sync.restEndDate != nil { sync.skipRest() }
        // Jumping also reopens final review when the undone set was the last.
        if sync.finished || sync.currentExercise?.id != logged.slotID,
           let index = sync.exercises.firstIndex(where: { $0.id == logged.slotID }) {
            sync.jump(to: index)
        }
        link.recount()
        await sync.drainWorkoutWriteOutboxes()
    }
}
