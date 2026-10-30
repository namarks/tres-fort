import Foundation

extension WeightUnit: Codable {}

/// A read-only projection of the runner, shared by the local iPad and its
/// authenticated phone-linked display. It carries no logging authority: a
/// linked iPad's controls are requests the iPhone applies or refuses.
struct WorkoutDisplayState: Codable, Equatable {
    enum Phase: String, Codable {
        case ready, active, rest, paused, exerciseComplete, review, finished, blocked

        /// The phases where the iPhone's own outline moves the workout.
        var offersExerciseChoice: Bool {
            switch self {
            case .ready, .rest, .exerciseComplete, .review: return true
            case .active, .paused, .finished, .blocked: return false
            }
        }
    }

    struct Step: Codable, Equatable {
        let slotID: String
        let exerciseName: String
        let weight: Double?
        let weightUnit: WeightUnit
        let reps: Int?
        let durationSeconds: Int?
        let setNumber: Int
        let totalSets: Int?
        let exerciseNumber: Int
        let totalExercises: Int
        let isWarmup: Bool
        let isBodyweight: Bool
        let isUnilateral: Bool
        let isPerHand: Bool
        let groupTitle: String?
        let roundNumber: Int?
        let totalRounds: Int?
        /// The effort that accompanies these exact runner inputs. Optional
        /// so display packets from before effort guidance still decode.
        var rpe: Double? = nil
    }

    /// One exercise in the workout outline, in the runner's order.
    struct OutlineEntry: Codable, Equatable {
        let slotID: String
        let exerciseName: String
        let setsDone: Int
        /// Nil in freestyle, which prescribes no count.
        let totalSets: Int?
        let isCurrent: Bool
        let isSkipped: Bool
        let isWarmup: Bool
        let groupTitle: String?
        /// The saved prescription, with loads in the display unit.
        let prescription: String
    }

    let phase: Phase
    let workoutName: String
    let current: Step?
    /// During rest this is the set to prepare for when rest ends. Otherwise
    /// it is the next set after the current one, following the runner scheduler.
    let next: Step?
    let restEndDate: Date?
    let timedEndDate: Date?
    let timedStartDate: Date?
    let workoutStartDate: Date?
    let message: String?
    let isFreestyle: Bool
    /// Every exercise in the workout. Optional so display packets from before
    /// the outline still decode; an older iPhone sends none.
    var outline: [OutlineEntry]? = nil
    /// The iPhone applies controls tapped on its linked iPad. An older iPhone
    /// leaves this out, and its iPad only displays the workout.
    var acceptsCommands: Bool? = nil

    /// A workout left open this long says nothing useful about its running time.
    static let longestShownWorkoutSeconds = 12 * 60 * 60

    /// The workout stopwatch at `date`. It is hidden once the workout has been
    /// open too long, so a forgotten workout doesn't show days of hours.
    func workoutSeconds(at date: Date) -> Int? {
        guard let workoutStartDate else { return nil }
        let seconds = max(0, Int(date.timeIntervalSince(workoutStartDate)))
        return seconds < Self.longestShownWorkoutSeconds ? seconds : nil
    }

    /// The exercise the workout is on, between sets too.
    var currentSlotID: String? { current?.slotID ?? outline?.first(where: \.isCurrent)?.slotID }

    /// The display compares this start with the real clock. The store-asset
    /// fixture freezes the model on its fictional date, so it supplies a
    /// plausible running time instead. Release builds use the model's start.
    private static func displayedWorkoutStart(_ start: Date?) -> Date? {
        #if DEBUG && targetEnvironment(simulator)
        if UIFixtureScenario.selected == .appStore, start != nil {
            return Date().addingTimeInterval(-1_457)
        }
        #endif
        return start
    }

    @MainActor
    static func project(sync: SyncModel, paused: Bool = false, displayUnit: WeightUnit? = nil) -> Self {
        let name = sync.selectedDay?.title ?? (sync.isFreestyle ? "Freestyle" : "Workout")
        // A replaced model (below) shows no workout at all.
        let outline = sync.terminalActionTarget == nil ? nil : outlineEntries(sync: sync, displayUnit: displayUnit)
        func state(_ phase: Phase, current: Step? = nil, next: Step? = nil,
                   message: String? = nil) -> Self {
            Self(phase: phase, workoutName: name, current: current, next: next,
                 restEndDate: phase == .rest ? sync.restEndDate : nil,
                 timedEndDate: phase == .active ? sync.timedEndDate : nil,
                 timedStartDate: phase == .active ? sync.timedStartDate : nil,
                 workoutStartDate: displayedWorkoutStart(sync.workoutStart), message: message, isFreestyle: sync.isFreestyle,
                 outline: outline)
        }

        // This public token is present only for the model's current account
        // and feature epoch. A replaced model must not keep giving instructions.
        guard sync.terminalActionTarget != nil else {
            return state(.blocked, message: "Reopen the workout to continue.")
        }
        if sync.todaySession?.status == "completed" {
            guard !sync.running || sync.finished else {
                return state(.blocked, message: "Reopen the workout to continue.")
            }
            return state(.finished, message: "Workout saved.")
        }
        if sync.hasPendingTerminalIntentForCurrentWorkout || sync.isTerminalMutationInFlight {
            return state(.blocked, message: "Saving workout. Wait before continuing.")
        }
        guard sync.running else {
            return state(.paused, message: "Open the workout to continue.")
        }
        if paused { return state(.paused, message: "Return to the workout to continue.") }
        // `finished` means that the runner reached review. Completion remains
        // a separate explicit, durable workout action.
        if sync.finished { return state(.review, message: "Review your sets and finish the workout.") }
        guard let exercise = sync.currentExercise else {
            return state(.blocked, message: sync.isFreestyle ? "Add an exercise to continue." : "Choose an exercise to continue.")
        }
        if sync.isSetEntryBlocked(exercise) {
            return state(.blocked, message: "Check the workout before continuing.")
        }
        // The outline can revisit a finished slot while other exercises are
        // unresolved. That cursor is neither a fourth set of three nor final
        // workout review; the existing runner action requires another choice.
        if !sync.isFreestyle, sync.runnerSetsDone(exercise) >= exercise.target_sets {
            return state(.exerciseComplete, message: "Choose another exercise to continue.")
        }

        let current = step(exercise, sync: sync, setNumber: sync.currentPhysicalSetNumber,
                           round: exercise.group_id == nil ? nil : sync.currentSetNumber, useInputs: true, displayUnit: displayUnit)
        if sync.timedActive {
            return state(.active, current: current, next: nextStep(after: exercise, sync: sync, displayUnit: displayUnit))
        }
        if sync.restEndDate != nil { return state(.rest, current: current, next: current) }
        return state(.ready, current: current, next: nextStep(after: exercise, sync: sync, displayUnit: displayUnit))
    }

    @MainActor
    private static func outlineEntries(sync: SyncModel, displayUnit: WeightUnit?) -> [OutlineEntry] {
        let groups = ExerciseGroupBlock.blocks(sync.exercises).filter(\.isGroup)
        return sync.exercises.map { exercise in
            OutlineEntry(slotID: exercise.id, exerciseName: exercise.exercise_name,
                setsDone: sync.runnerSetsDone(exercise),
                totalSets: sync.isFreestyle ? nil : exercise.target_sets,
                isCurrent: exercise.id == sync.currentExercise?.id,
                isSkipped: sync.isSkipped(exercise), isWarmup: exercise.isWarmup,
                groupTitle: groups.first { $0.members.contains { $0.id == exercise.id } }?.title,
                prescription: exercise.prescriptionLabel(in: displayUnit ?? exercise.targetWeightUnit))
        }
    }

    @MainActor
    private static func step(_ exercise: TemplateExercise, sync: SyncModel, setNumber: Int,
                             round: Int? = nil, useInputs: Bool = false, displayUnit: WeightUnit? = nil) -> Step {
        let group = ExerciseGroupBlock.blocks(sync.exercises).first {
            $0.isGroup && $0.members.contains { $0.id == exercise.id }
        }
        let unit = displayUnit ?? exercise.targetWeightUnit
        let input = useInputs ? sync.currentInputState : sync.runnerPreviewInput(for: exercise)
        let weight = input?.weight
        return Step(slotID: exercise.id, exerciseName: exercise.exercise_name,
            weight: exercise.showsLoadControl ? weight.map { exercise.targetWeightUnit.convert($0, to: unit) } : nil,
            weightUnit: unit,
            reps: exercise.isTimed ? nil : input?.reps,
            durationSeconds: exercise.isTimed ? input?.durationSeconds : nil,
            setNumber: setNumber, totalSets: sync.isFreestyle ? nil : exercise.target_sets,
            exerciseNumber: (sync.exercises.firstIndex { $0.id == exercise.id } ?? 0) + 1,
            totalExercises: sync.exercises.count, isWarmup: exercise.isWarmup,
            isBodyweight: exercise.allowsAssistance,
            isUnilateral: exercise.isUnilateral, isPerHand: exercise.isPerHand,
            groupTitle: group?.title, roundNumber: round, totalRounds: group?.rounds,
            rpe: input?.rpe)
    }

    @MainActor
    private static func nextStep(after current: TemplateExercise, sync: SyncModel, displayUnit: WeightUnit?) -> Step? {
        // Freestyle deliberately has no prescribed finish or automatic move to
        // another movement. The member can keep logging this exercise.
        if sync.isFreestyle {
            return step(current, sync: sync, setNumber: sync.currentPhysicalSetNumber + 1, useInputs: true, displayUnit: displayUnit)
        }
        if let next = sync.nextGroupExercise(afterLogging: current) {
            let members = sync.exercises.filter {
                $0.group_id == current.group_id && (!sync.isSkipped($0) || $0.id == current.id)
            }
            let completedRound = members.map {
                min($0.target_sets, sync.runnerSetsDone($0) + ($0.id == current.id ? 1 : 0))
            }.min() ?? 0
            return step(next, sync: sync,
                setNumber: sync.runnerSetsDone(next) + (next.id == current.id ? 2 : 1),
                round: completedRound + 1, useInputs: next.id == current.id, displayUnit: displayUnit)
        }
        if current.group_id == nil, sync.runnerSetsDone(current) + 1 < current.target_sets {
            return step(current, sync: sync, setNumber: sync.currentPhysicalSetNumber + 1, useInputs: true, displayUnit: displayUnit)
        }
        let exercises = sync.exercises
        guard !exercises.isEmpty else { return nil }
        for offset in 1...exercises.count {
            let candidate = exercises[(sync.exerciseIndex + offset) % exercises.count]
            let completed = sync.runnerSetsDone(candidate) + (candidate.id == current.id ? 1 : 0)
            guard !sync.isSkipped(candidate), completed < candidate.target_sets else { continue }
            // A newly entered group begins at its least-complete member, in
            // stored order, just as runner normalization does after a commit.
            let group = candidate.group_id.map { id in
                exercises.filter { $0.group_id == id && !sync.isSkipped($0) }
            } ?? []
            let minimum = group.map { min(sync.runnerSetsDone($0), $0.target_sets) }.min()
            let selected = minimum.flatMap { value in
                group.first { sync.runnerSetsDone($0) == value && value < $0.target_sets }
            } ?? candidate
            return step(selected, sync: sync, setNumber: sync.runnerSetsDone(selected) + 1,
                        round: minimum.map { $0 + 1 }, displayUnit: displayUnit)
        }
        return nil
    }
}
