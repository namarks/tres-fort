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

/// The step a recording run is on: what it asks for, what's left of it and
/// what comes next, with a way to skip it.
struct RunPlanStepBanner: View {
    @ObservedObject var model: RunRecorderModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let steps = model.planSteps
            let progress = model.run?.plan?.progress ?? RunPlanProgress()
            let moving = model.run?.activeSeconds(at: context.date) ?? 0
            let meters = model.run?.distanceMeters ?? 0
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    if let current = model.currentPlanStep {
                        Text(position(current, index: progress.stepIndex, count: steps.count))
                            .font(Theme.mono(11, .bold)).tracking(1).foregroundStyle(Theme.accent)
                        Text(RunPlanFormat.text(current.step, unit: model.unit))
                            .font(Theme.mono(17, .bold)).foregroundStyle(Theme.text)
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            if let left = progress.remaining(steps, movingSeconds: moving, meters: meters,
                                                             unit: model.unit) {
                                Text(left).foregroundStyle(Theme.text).monospacedDigit()
                            }
                            if steps.indices.contains(progress.stepIndex + 1) {
                                Text("Next: " + RunPlanFormat.text(steps[progress.stepIndex + 1].step,
                                                                   unit: model.unit))
                                    .foregroundStyle(Theme.muted).lineLimit(1)
                            }
                        }
                        .font(Theme.mono(13))
                    } else {
                        Text("PLAN DONE")
                            .font(Theme.mono(11, .bold)).tracking(1).foregroundStyle(Theme.accent)
                        Text("Keep going or end the run.")
                            .font(Theme.mono(15)).foregroundStyle(Theme.text)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if model.currentPlanStep != nil {
                    Button("Skip") { model.skipPlanStep() }
                        .font(Theme.mono(14, .bold))
                        .buttonStyle(.bordered)
                        .tint(Theme.text)
                        .frame(minHeight: 44)
                        .accessibilityLabel("Skip this step")
                        .accessibilityIdentifier("runRecorder.skipStep")
                }
            }
            .padding(12)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("runRecorder.planStep")
        }
    }

    /// "STEP 3 OF 10 · REP 2 OF 4".
    private func position(_ step: RunPlan.ExpandedStep, index: Int, count: Int) -> String {
        var text = "STEP \(index + 1) OF \(count)"
        if let round = step.round, let rounds = step.rounds { text += " · REP \(round) OF \(rounds)" }
        return text
    }
}
