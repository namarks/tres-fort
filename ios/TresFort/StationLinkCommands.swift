import Foundation

/// Applies a control tapped on a linked iPad to the iPhone runner, through
/// the same guarded SyncModel action as the iPhone's own button. The
/// controller has already checked that a set control names the set it last
/// showed; this checks the runner itself, which may have moved since.
@MainActor
enum StationLinkCommandRunner {
    static func apply(_ command: StationLinkCommand, to sync: SyncModel) async -> StationLinkCommandReceipt {
        // A partner workout has its own controls, and a replaced model
        // (another account or session) takes none.
        guard sync.running, !sync.isPartnerWorkout, sync.terminalActionTarget != nil else {
            return .refused(command, StationLinkCommandReceipt.openWorkout)
        }
        guard !sync.hasPendingTerminalIntentForCurrentWorkout, !sync.isTerminalMutationInFlight else {
            return .refused(command, "Your iPhone is saving the workout. Wait, then try again.")
        }
        // Values, rests and choices changed on the iPhone reach its published
        // display a moment later. Act only while the runner still shows
        // exactly what the iPad showed.
        guard command.matches(WorkoutDisplayState.project(sync: sync, displayUnit: command.step?.weightUnit)) else {
            return .refused(command, StationLinkCommandReceipt.movedOn)
        }
        switch command.action {
        case .endRest:
            if sync.restEndDate != nil { sync.skipRest() }
            return .accepted(command)
        case .select(let slotID):
            // As on the iPhone, a running hold stays until it is stopped.
            guard !sync.timedActive else {
                return .refused(command, "Stop the timer before choosing another exercise.")
            }
            guard let index = sync.exercises.firstIndex(where: { $0.id == slotID }) else {
                return .refused(command, "That exercise is no longer in this workout.")
            }
            sync.jump(to: index)
            return .accepted(command)
        case .logSet, .startTimer, .stopTimer, .setValues:
            return await applyToShownSet(command, sync: sync)
        }
    }

    private static func applyToShownSet(_ command: StationLinkCommand, sync: SyncModel) async -> StationLinkCommandReceipt {
        guard !sync.finished, let exercise = sync.currentExercise, let step = command.step,
              step.slotID == exercise.id, step.setNumber == sync.currentPhysicalSetNumber else {
            return .refused(command, StationLinkCommandReceipt.movedOn)
        }
        guard !sync.isSetEntryBlocked(exercise) else {
            return .refused(command, "Check the workout on your iPhone before continuing.")
        }
        switch command.action {
        case .logSet:
            guard !exercise.isTimed, !sync.timedActive else {
                return .refused(command, StationLinkCommandReceipt.movedOn)
            }
            let before = sync.lastRunnerSetID
            await sync.logCurrentSet(expected: exercise, expectedSetNumber: step.setNumber)
            return sync.lastRunnerSetID != before ? .accepted(command)
                : .refused(command, "Your iPhone couldn’t log that set. Check your iPhone.")
        case .startTimer:
            guard exercise.isTimed, !sync.timedActive else {
                return .refused(command, StationLinkCommandReceipt.movedOn)
            }
            // A start can first wait on the previous timer's cue. Answer once
            // the timer runs, or say that it didn't start.
            await sync.startTimedSet(expected: exercise, expectedSetNumber: step.setNumber)?.value
            return sync.timedActive ? .accepted(command)
                : .refused(command, "Your iPhone couldn’t start the timer. Check your iPhone.")
        case .stopTimer:
            guard exercise.isTimed, sync.timedActive else {
                return .refused(command, StationLinkCommandReceipt.movedOn)
            }
            // The iPhone ignores a stop in the first seconds, which is a
            // reflexive second tap rather than a finished hold.
            guard sync.timedElapsed >= 2 else {
                return .refused(command, "Let the timer run a few seconds before stopping it.")
            }
            let before = sync.lastRunnerSetID
            await sync.stopTimedSet()
            return sync.lastRunnerSetID != before ? .accepted(command)
                : .refused(command, "Your iPhone couldn’t log that set. Check your iPhone.")
        case .setValues(let values, let unit):
            guard !sync.timedActive else {
                return .refused(command, "Stop the timer before changing this set.")
            }
            let stored = exercise.targetWeightUnit
            // The iPad shows loads in the iPhone's display unit. An unchanged
            // or hidden load keeps its exact stored value instead of a
            // round trip through another unit.
            let unchanged = abs(stored.convert(sync.weight, to: unit) - values.weight) < 0.000_001
            let weight = !exercise.showsLoadControl || unchanged ? sync.weight : unit.convert(values.weight, to: stored)
            let converted = SetCorrectionValues(weight: weight, reps: values.reps, rpe: values.rpe,
                durationSeconds: exercise.isTimed ? values.durationSeconds : nil)
            guard sync.setRunnerValues(converted, expected: RunnerPrescription(exercise)) else {
                return .refused(command, "Your iPhone couldn’t change that set. Check your iPhone.")
            }
            return .accepted(command)
        case .endRest, .select:
            return .refused(command, StationLinkCommandReceipt.movedOn)
        }
    }
}
