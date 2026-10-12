#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit synthetic display input for UI journeys. This exercises the same
/// receiver and presentation as a phone message without starting discovery,
/// overriding connectivity, reading a link key, or writing workout data. The
/// "controls" and "reconnecting" modes stand in for an iPhone that applies
/// the iPad's controls to a synthetic workout.
@MainActor
enum IpadWorkoutDisplayUIFixture {
    @discardableResult
    static func installIfRequested(on station: StationLinkStation, accountID: String?) -> Bool {
        guard UIFixtureScenario.selected == .appStore, accountID == "synthetic-ui-user",
              let mode = ProcessInfo.processInfo.environment["TRESFORT_UI_STATION_DISPLAY"],
              ["ready", "rest", "disconnected", "controls", "reconnecting"].contains(mode) else { return false }

        if mode == "controls" || mode == "reconnecting" {
            let phone = SyntheticLinkedPhone(station: station)
            station.installUIFixturePhone { phone.apply($0) }
            phone.publish()
            if mode == "reconnecting" { station.dropUIFixturePhone() }
            return true
        }

        // An unsupported camera movement still needs complete instructions.
        let current = WorkoutDisplayState.Step(slotID: "synthetic-display-face-pull",
            exerciseName: "Cable Face Pull", weight: 22.5, weightUnit: .kg,
            reps: 12, durationSeconds: nil, setNumber: 2, totalSets: 3,
            exerciseNumber: 2, totalExercises: 4, isWarmup: false, isBodyweight: false,
            isUnilateral: false, isPerHand: false, groupTitle: nil,
            roundNumber: nil, totalRounds: nil, rpe: 8)
        let next = WorkoutDisplayState.Step(slotID: "synthetic-display-plank",
            exerciseName: "Plank", weight: nil, weightUnit: .kg,
            reps: nil, durationSeconds: 45, setNumber: 1, totalSets: 2,
            exerciseNumber: 3, totalExercises: 4, isWarmup: false, isBodyweight: true,
            isUnilateral: false, isPerHand: false, groupTitle: nil,
            roundNumber: nil, totalRounds: nil, rpe: 7)
        let resting = mode == "rest"
        station.receive(.display(WorkoutDisplayState(phase: resting ? .rest : .ready,
            workoutName: "Synthetic phone workout", current: current,
            next: resting ? current : next,
            restEndDate: resting ? Date().addingTimeInterval(300) : nil,
            timedEndDate: nil, timedStartDate: nil, workoutStartDate: nil,
            message: nil, isFreestyle: false)))
        if mode == "disconnected" {
            // Clearing the received projection must remove stale instructions.
            station.receive(.display(nil))
        }
        return true
    }
}

/// A synthetic iPhone runner: it applies each control to its workout, then
/// publishes the new display before answering, in the iPhone's order.
@MainActor
private final class SyntheticLinkedPhone {
    private struct Slot {
        let id: String
        let name: String
        var weight: Double?
        var reps: Int?
        var duration: Int?
        var rpe: Double?
        let sets: Int
        var done = 0
    }

    private weak var station: StationLinkStation?
    private var slots = [
        Slot(id: "synthetic-control-face-pull", name: "Cable Face Pull", weight: 22.5, reps: 12, rpe: 8, sets: 3),
        Slot(id: "synthetic-control-plank", name: "Plank", duration: 45, rpe: 7, sets: 2),
        Slot(id: "synthetic-control-goblet", name: "Goblet Squat", weight: 24, reps: 10, sets: 3),
    ]
    private var index = 0
    private var phase: WorkoutDisplayState.Phase = .ready
    private var restEnd: Date?
    private var timerStart: Date?
    private let started = Date().addingTimeInterval(-754)

    init(station: StationLinkStation) { self.station = station }

    func apply(_ command: StationLinkCommand) {
        // As on an iPhone, a control applies only to what it shows.
        guard command.matches(shown) else {
            return answer(.refused(command, StationLinkCommandReceipt.movedOn))
        }
        switch command.action {
        case .logSet, .stopTimer:
            slots[index].done += 1
            timerStart = nil
            if slots[index].done >= slots[index].sets,
               let next = slots.indices.first(where: { slots[$0].done < slots[$0].sets }) {
                index = next
            }
            phase = .rest
            restEnd = Date().addingTimeInterval(90)
        case .endRest:
            phase = .ready
            restEnd = nil
        case .startTimer:
            phase = .active
            timerStart = Date()
        case .select(let slotID):
            index = slots.firstIndex { $0.id == slotID } ?? index
            phase = slots[index].done >= slots[index].sets ? .exerciseComplete : .ready
            restEnd = nil
        case .setValues(let values, _):
            if slots[index].weight != nil { slots[index].weight = values.weight }
            if slots[index].duration != nil { slots[index].duration = values.durationSeconds }
            else { slots[index].reps = values.reps }
            slots[index].rpe = values.rpe
        }
        publish()
        answer(.accepted(command))
    }

    private var shown: WorkoutDisplayState?

    func publish() {
        let current = phase == .exerciseComplete ? nil : step(index)
        let following = slots.indices.first { $0 != index && slots[$0].done < slots[$0].sets }
        let next = phase == .rest ? current : following.map { step($0) }
        var state = WorkoutDisplayState(phase: phase, workoutName: "Synthetic phone workout",
            current: current, next: next,
            restEndDate: phase == .rest ? restEnd : nil,
            timedEndDate: phase == .active ? timerStart?.addingTimeInterval(TimeInterval(slots[index].duration ?? 0)) : nil,
            timedStartDate: phase == .active ? timerStart : nil,
            workoutStartDate: started,
            message: phase == .exerciseComplete ? "Choose another exercise to continue." : nil,
            isFreestyle: false)
        state.outline = slots.enumerated().map { offset, slot in
            WorkoutDisplayState.OutlineEntry(slotID: slot.id, exerciseName: slot.name,
                setsDone: slot.done, totalSets: slot.sets, isCurrent: offset == index,
                isSkipped: false, isWarmup: false, groupTitle: nil,
                prescription: "\(slot.sets) × " + (slot.duration.map { "\($0)s" } ?? "\(slot.reps ?? 0)"))
        }
        state.acceptsCommands = true
        shown = state
        station?.receive(.display(state))
    }

    private func step(_ position: Int) -> WorkoutDisplayState.Step {
        let slot = slots[position]
        return WorkoutDisplayState.Step(slotID: slot.id, exerciseName: slot.name,
            weight: slot.weight, weightUnit: .kg, reps: slot.duration == nil ? slot.reps : nil,
            durationSeconds: slot.duration, setNumber: min(slot.done + 1, slot.sets), totalSets: slot.sets,
            exerciseNumber: position + 1, totalExercises: slots.count, isWarmup: false,
            isBodyweight: slot.weight == nil, isUnilateral: false, isPerHand: false,
            groupTitle: nil, roundNumber: nil, totalRounds: nil, rpe: slot.rpe)
    }

    private func answer(_ receipt: StationLinkCommandReceipt) {
        station?.receive(.commandReceipt(receipt))
    }
}
#endif
