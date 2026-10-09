#if DEBUG && targetEnvironment(simulator)
import Foundation

/// Explicit synthetic display input for UI journeys. This exercises the same
/// receiver and presentation as a phone message without starting discovery,
/// overriding connectivity, reading a link key, or writing workout data.
@MainActor
enum IpadWorkoutDisplayUIFixture {
    @discardableResult
    static func installIfRequested(on station: StationLinkStation, accountID: String?) -> Bool {
        guard UIFixtureScenario.selected == .appStore, accountID == "synthetic-ui-user",
              let mode = ProcessInfo.processInfo.environment["TRESFORT_UI_STATION_DISPLAY"],
              ["ready", "rest", "disconnected"].contains(mode) else { return false }

        // An unsupported camera movement still needs complete instructions.
        let current = WorkoutDisplayState.Step(slotID: "synthetic-display-face-pull",
            exerciseName: "Cable Face Pull", weight: 22.5, weightUnit: .kg,
            reps: 12, durationSeconds: nil, setNumber: 2, totalSets: 3,
            exerciseNumber: 2, totalExercises: 4, isWarmup: false, isBodyweight: false,
            isUnilateral: false, isPerHand: false, groupTitle: nil,
            roundNumber: nil, totalRounds: nil)
        let next = WorkoutDisplayState.Step(slotID: "synthetic-display-plank",
            exerciseName: "Plank", weight: nil, weightUnit: .kg,
            reps: nil, durationSeconds: 45, setNumber: 1, totalSets: 2,
            exerciseNumber: 3, totalExercises: 4, isWarmup: false, isBodyweight: true,
            isUnilateral: false, isPerHand: false, groupTitle: nil,
            roundNumber: nil, totalRounds: nil)
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
#endif
