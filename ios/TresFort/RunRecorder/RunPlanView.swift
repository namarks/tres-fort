import SwiftUI

/// A planned run's steps, one per line, with repeat groups indented under
/// their count.
struct RunPlanStepsView: View {
    let plan: RunPlan
    let unit: RunDistanceUnit
    var size: CGFloat = 13

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(RunPlanFormat.lines(plan, unit: unit)) { line in
                Text(line.text)
                    .font(Theme.mono(size))
                    .foregroundStyle(line.indented ? Theme.text : Theme.muted)
                    .padding(.leading, line.indented ? 16 : 0)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("runPlan.steps")
    }
}

/// What an outdoor run slot asks for: its steps, or a one-line label for a
/// run planned without them. Reads the recorder's miles-or-kilometers choice.
struct PlannedRunPrescription: View {
    let exercise: TemplateExercise
    var size: CGFloat = 13
    @AppStorage(RunDistanceUnit.preferenceKey) private var unitRaw = RunDistanceUnit.miles.rawValue
    private var unit: RunDistanceUnit { RunDistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        if let plan = exercise.runPlan {
            RunPlanStepsView(plan: plan, unit: unit, size: size)
        } else {
            Text(exercise.runPrescriptionLabel(in: unit))
                .font(Theme.mono(size)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The plan on the recorder's start screen. Following it step by step while
/// recording comes later; for now the member reads it before starting.
struct PlannedRunCard: View {
    let run: PlannedRun
    let unit: RunDistanceUnit
    /// About eight lines; more scroll.
    static let maxStepsHeight: CGFloat = 170

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(run.workoutName.uppercased())
                .font(Theme.mono(12, .bold)).tracking(1).foregroundStyle(Theme.accent)
            if let plan = run.plan {
                // A long plan scrolls inside the card, so the recorder's
                // controls below it stay on screen.
                ViewThatFits(in: .vertical) {
                    RunPlanStepsView(plan: plan, unit: unit)
                    ScrollView { RunPlanStepsView(plan: plan, unit: unit) }
                        .accessibilityIdentifier("runRecorder.plannedRun.scroll")
                }
                .frame(maxHeight: Self.maxStepsHeight)
            } else {
                Text(run.durationSeconds.map { "Run · " + RunPlanFormat.duration($0) } ?? "Run at your own pace")
                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("runRecorder.plannedRun")
    }
}
