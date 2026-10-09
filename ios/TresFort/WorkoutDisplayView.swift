import SwiftUI

/// A presentation of the authoritative runner, shared by a workout on this
/// iPad and a live display controlled by an iPhone. The caller owns all actions.
struct WorkoutDisplayView<Controls: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let state: WorkoutDisplayState
    let isPhoneControlled: Bool
    let trackingCount: String?
    let trackingStatus: String?
    private let controls: Controls

    init(state: WorkoutDisplayState, isPhoneControlled: Bool = false,
         trackingCount: String? = nil, trackingStatus: String? = nil,
         @ViewBuilder controls: () -> Controls) {
        self.state = state
        self.isPhoneControlled = isPhoneControlled
        self.trackingCount = trackingCount
        self.trackingStatus = trackingStatus
        self.controls = controls()
    }

    var body: some View {
        GeometryReader { geometry in
            TimelineView(.periodic(from: .now, by: 0.25)) { context in
                let accessible = dynamicTypeSize.isAccessibilitySize
                let compact = accessible || geometry.size.width < 650 || geometry.size.height < 500
                let landscape = geometry.size.width > geometry.size.height
                let layout = DisplayLayout(landscape: landscape, compact: compact)
                content(at: context.date, layout: layout)
                    .padding(compact ? 16 : 24)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Theme.background)
            }
        }
        .foregroundStyle(Theme.text)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ipadWorkout.display")
    }

    private func content(at date: Date, layout: DisplayLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            header
                .fixedSize(horizontal: false, vertical: true)
            // The card's intrinsic height must never move a logging target.
            // Reserve the controls first; only the display region can scroll
            // or adapt its density as rest, timers and tracking change phase.
            GeometryReader { region in
                let fitted = DisplayLayout(landscape: layout.landscape,
                    compact: layout.compact, availableHeight: region.size.height)
                if layout.compact {
                    ScrollView {
                        cards(at: date, layout: fitted)
                            .frame(minHeight: region.size.height)
                    }
                } else {
                    cards(at: date, layout: fitted)
                        .frame(width: region.size.width, height: region.size.height, alignment: .top)
                        .clipped()
                }
            }
            controls
                .frame(maxWidth: .infinity)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
                .background(Theme.bg)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("ipadWorkout.controls")
        }
    }

    @ViewBuilder
    private func cards(at date: Date, layout: DisplayLayout) -> some View {
        if layout.landscape && !layout.compact {
            HStack(alignment: .top, spacing: layout.spacing) {
                focus(at: date, layout: layout)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                nextStep(layout: layout)
                    .frame(width: 240, alignment: .leading)
            }
        } else {
            VStack(alignment: .leading, spacing: layout.spacing) {
                focus(at: date, layout: layout)
                    .frame(maxWidth: .infinity, maxHeight: layout.compact ? nil : .infinity)
                nextStep(layout: layout)
            }
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                workoutHeading
                Spacer(minLength: 12)
                sourceLabel
            }
            VStack(alignment: .leading, spacing: 6) {
                workoutHeading
                sourceLabel
            }
        }
    }

    private var workoutHeading: some View {
        Text(state.workoutName.uppercased())
            .font(Theme.display(26))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var sourceLabel: some View {
        Label(isPhoneControlled ? "IPHONE CONTROLS" : "THIS IPAD", systemImage: isPhoneControlled ? "iphone" : "ipad")
            .font(Theme.mono(12, .bold))
            .foregroundStyle(Theme.muted)
            .accessibilityLabel(isPhoneControlled ? "Workout controlled on iPhone" : "Workout controlled on this iPad")
            .accessibilityIdentifier("ipadWorkout.source")
    }

    private func focus(at date: Date, layout: DisplayLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.spacing) {
            Text(phaseLabel(at: date))
                .font(Theme.mono(layout.labelSize, .bold))
                .foregroundStyle(phaseColor(at: date))
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("ipadWorkout.phase")

            if showsCurrentStep, let step = state.current {
                Text(step.exerciseName.uppercased())
                    .font(Theme.display(layout.titleSize))
                    .lineLimit(layout.compact ? nil : 2)
                    .minimumScaleFactor(0.65)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("runner.exerciseTitle")

                Text(position(of: step))
                    .font(Theme.mono(layout.labelSize))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ipadWorkout.position")

                if let deadline = countdownDeadline {
                    countdown(until: deadline, at: date, layout: layout)
                    compactTarget(step, layout: layout)
                } else if state.phase == .active, let start = state.timedStartDate {
                    elapsed(since: start, at: date, layout: layout)
                    compactTarget(step, layout: layout)
                } else if let trackingCount, !trackingCount.isEmpty {
                    metric(value: trackingCount, label: "REPS COUNTED", size: layout.numberSize)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(trackingCount) reps counted")
                        .accessibilityIdentifier("ipadWorkout.trackingCount")
                    compactTarget(step, layout: layout)
                } else {
                    target(step, layout: layout)
                }

                if !layout.compact { Spacer(minLength: 0) }
                if !layout.tight || trackingStatus != nil || state.message != nil {
                    Text(instruction(at: date, step: step))
                        .font(.system(size: layout.compact || layout.tight ? 20 : 22, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ipadWorkout.instruction")
                }
            } else {
                Text(completionTitle)
                    .font(Theme.display(layout.titleSize))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ipadWorkout.status")
                if let message = state.message {
                    Text(message)
                        .font(.title3)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !layout.compact { Spacer(minLength: 0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(layout.cardPadding)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private func compactTarget(_ step: WorkoutDisplayState.Step, layout: DisplayLayout) -> some View {
        Text(targetSummary(step))
            .font(Theme.mono(layout.compact || layout.tight ? 22 : 26, .bold))
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("ipadWorkout.target")
    }

    private func target(_ step: WorkoutDisplayState.Step, layout: DisplayLayout) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                if let weight = step.weight, weight != 0 {
                    metric(value: loadNumber(step, weight: weight),
                           label: loadLabel(step, weight: weight), size: layout.numberSize)
                    Text("×").font(Theme.display(40)).foregroundStyle(Theme.dim)
                        .accessibilityHidden(true)
                }
                if let seconds = step.durationSeconds {
                    metric(value: "\(seconds)", label: "SECONDS", size: layout.numberSize)
                } else if let reps = step.reps {
                    metric(value: "\(reps)", label: step.isUnilateral ? "REPS / SIDE" : "REPS", size: layout.numberSize)
                }
            }
            if step.isBodyweight && (step.weight ?? 0) == 0 {
                Text("BODYWEIGHT")
                    .font(Theme.mono(18, .bold))
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(targetSummary(step))
        .accessibilityIdentifier("ipadWorkout.target")
    }

    private func metric(value: String, label: String, size: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value)
                .font(Theme.number(size))
                .lineLimit(1)
                .minimumScaleFactor(0.45)
                .foregroundStyle(Theme.accent)
            Text(label)
                .font(Theme.mono(size < 70 ? 14 : 16, .bold))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func countdown(until deadline: Date, at date: Date, layout: DisplayLayout) -> some View {
        let seconds = max(0, Int(ceil(deadline.timeIntervalSince(date))))
        return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(Theme.number(layout.numberSize + 12))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(seconds == 0 ? Theme.done : Theme.accent)
            .accessibilityLabel(state.phase == .rest ? "Rest remaining" : "Set remaining")
            .accessibilityValue("\(seconds) seconds")
            .accessibilityIdentifier("ipadWorkout.countdown")
    }

    private func elapsed(since start: Date, at date: Date, layout: DisplayLayout) -> some View {
        let seconds = max(0, Int(date.timeIntervalSince(start)))
        return Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(Theme.number(layout.numberSize + 12))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel("Set elapsed")
            .accessibilityValue("\(seconds) seconds")
            .accessibilityIdentifier("ipadWorkout.elapsed")
    }

    @ViewBuilder
    private func nextStep(layout: DisplayLayout) -> some View {
        if showsCurrentStep, let next = state.next {
            VStack(alignment: .leading, spacing: 10) {
                Text("UP NEXT")
                    .font(Theme.mono(14, .bold))
                    .foregroundStyle(Theme.muted)
                Text(next.exerciseName.uppercased())
                    .font(Theme.display(layout.landscape ? 34 : 32))
                    .lineLimit(layout.compact ? nil : 3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                Text(position(of: next))
                    .font(Theme.mono(14))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Text(targetSummary(next))
                    .font(Theme.mono(20, .bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 16))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("ipadWorkout.next")
        }
    }

    private var showsCurrentStep: Bool {
        switch state.phase {
        case .ready, .active, .rest: return true
        case .paused, .exerciseComplete, .review, .finished, .blocked: return false
        }
    }

    private var countdownDeadline: Date? {
        switch state.phase {
        case .rest: return state.restEndDate
        case .active: return state.timedEndDate
        default: return nil
        }
    }

    private func phaseLabel(at date: Date) -> String {
        switch state.phase {
        case .ready: return "READY FOR YOUR SET"
        case .active:
            return state.timedEndDate.map { $0 <= date } == true ? "SET TIMER COMPLETE" : "SET IN PROGRESS"
        case .rest:
            return state.restEndDate.map { $0 <= date } == true ? "REST COMPLETE" : "REST"
        case .paused: return "WORKOUT PAUSED"
        case .exerciseComplete: return "EXERCISE COMPLETE"
        case .review: return "SETS COMPLETE"
        case .finished: return "WORKOUT COMPLETE"
        case .blocked: return "WORKOUT UNAVAILABLE"
        }
    }

    private func phaseColor(at date: Date) -> Color {
        if state.phase == .finished || state.phase == .review || state.phase == .exerciseComplete || countdownDeadline.map({ $0 <= date }) == true {
            return Theme.done
        }
        return state.phase == .blocked || state.phase == .paused ? Theme.muted : Theme.accent
    }

    private var completionTitle: String {
        switch state.phase {
        case .exerciseComplete: return "CHOOSE ANOTHER EXERCISE"
        case .review: return isPhoneControlled ? "REVIEW ON YOUR IPHONE" : "REVIEW YOUR WORKOUT"
        case .finished: return "WORKOUT SAVED"
        case .blocked: return isPhoneControlled ? "CHECK YOUR IPHONE" : "CHECK YOUR WORKOUT"
        case .paused: return isPhoneControlled ? "RESUME ON YOUR IPHONE" : "RESUME YOUR WORKOUT"
        default: return isPhoneControlled ? "WAITING FOR YOUR IPHONE" : "READY WHEN YOU ARE"
        }
    }

    private func instruction(at date: Date, step: WorkoutDisplayState.Step) -> String {
        if let trackingStatus, !trackingStatus.isEmpty { return trackingStatus }
        if let message = state.message, !message.isEmpty { return message }
        switch state.phase {
        case .rest:
            return state.restEndDate.map { $0 <= date } == true ? "Ready for your next set." : "Recover and get ready for this set."
        case .active:
            if state.timedEndDate == nil {
                return isPhoneControlled ? "Stop the timer on your iPhone when finished." : "Stop the timer when you are finished."
            }
            return state.timedEndDate.map { $0 <= date } == true
                ? (isPhoneControlled ? "Log the set on your iPhone." : "Log your completed set.")
                : "Keep going until the timer finishes."
        case .paused: return isPhoneControlled ? "Resume the workout on your iPhone." : "Resume when you are ready."
        default:
            if step.isUnilateral { return "Complete both sides, then log one set." }
            return isPhoneControlled ? "Your iPhone controls and logs this workout." : "Complete the set, then log it below."
        }
    }

    private func position(of step: WorkoutDisplayState.Step) -> String {
        let setTotal = step.totalSets.map { " OF \($0)" } ?? ""
        let set = "SET \(step.setNumber)\(setTotal)"
        if let group = step.groupTitle, let round = step.roundNumber {
            let total = step.totalRounds.map { " OF \($0)" } ?? ""
            return "\(group.uppercased()) · ROUND \(round)\(total) · \(set)"
        }
        return (step.isWarmup ? "WARM-UP · " : "") + set
    }

    private func loadNumber(_ step: WorkoutDisplayState.Step, weight: Double) -> String {
        let prefix = step.isBodyweight && weight > 0 ? "+" : ""
        return prefix + WeightUnit.text(abs(weight))
    }

    private func loadLabel(_ step: WorkoutDisplayState.Step, weight: Double) -> String {
        let qualifier = weight < 0 ? " ASSIST" : step.isPerHand ? " / HAND" : ""
        return step.weightUnit.rawValue.uppercased() + qualifier
    }

    private func targetSummary(_ step: WorkoutDisplayState.Step) -> String {
        var parts: [String] = []
        if let weight = step.weight, weight != 0 {
            let qualifier = weight < 0 ? " assistance" : step.isPerHand ? " each hand" : ""
            parts.append(loadNumber(step, weight: weight) + " " + step.weightUnit.rawValue + qualifier)
        } else if step.isBodyweight {
            parts.append("Bodyweight")
        }
        if let seconds = step.durationSeconds { parts.append("\(seconds) seconds") }
        else if let reps = step.reps { parts.append("\(reps) reps" + (step.isUnilateral ? " per side" : "")) }
        return parts.joined(separator: " × ")
    }

    private struct DisplayLayout {
        let landscape: Bool
        let compact: Bool
        var availableHeight: CGFloat? = nil
        var tight: Bool { !compact && landscape && (availableHeight ?? .infinity) < 450 }
        var spacing: CGFloat { compact ? 16 : tight ? 8 : 20 }
        var cardPadding: CGFloat { compact ? 20 : tight ? 16 : 28 }
        var labelSize: CGFloat { compact ? 16 : tight ? 14 : 18 }
        var titleSize: CGFloat { compact ? 42 : tight ? 44 : landscape ? 60 : 68 }
        var numberSize: CGFloat { compact ? 64 : tight ? 64 : landscape ? 88 : 104 }
    }
}
