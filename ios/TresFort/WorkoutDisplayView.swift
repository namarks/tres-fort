import SwiftUI

/// A short line above the workout: the link reconnecting, or why a control
/// didn't take effect.
struct WorkoutDisplayBanner: Equatable {
    let text: String
    let systemImage: String
    let identifier: String
}

/// A presentation of the authoritative runner, shared by a workout on this
/// iPad and a live display controlled by an iPhone. The caller owns all actions.
struct WorkoutDisplayView<Controls: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let state: WorkoutDisplayState
    let isPhoneControlled: Bool
    /// A phone-controlled display whose controls here reach the iPhone.
    let controlsHere: Bool
    let trackingCount: String?
    let trackingStatus: String?
    /// The workout outline takes the place of the next-step card.
    let showsOutline: Bool
    let banner: WorkoutDisplayBanner?
    /// Choosing an exercise in the outline, while `outlineEnabled`.
    let onSelectOutline: ((String) -> Void)?
    let outlineEnabled: Bool
    private let controls: Controls

    init(state: WorkoutDisplayState, isPhoneControlled: Bool = false, controlsHere: Bool = false,
         trackingCount: String? = nil, trackingStatus: String? = nil,
         showsOutline: Bool = false, banner: WorkoutDisplayBanner? = nil,
         onSelectOutline: ((String) -> Void)? = nil, outlineEnabled: Bool = false,
         @ViewBuilder controls: () -> Controls) {
        self.state = state
        self.isPhoneControlled = isPhoneControlled
        self.controlsHere = controlsHere
        self.trackingCount = trackingCount
        self.trackingStatus = trackingStatus
        self.showsOutline = showsOutline
        self.banner = banner
        self.onSelectOutline = onSelectOutline
        self.outlineEnabled = outlineEnabled
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
            header(at: date)
                .fixedSize(horizontal: false, vertical: true)
            if let banner {
                Label(banner.text, systemImage: banner.systemImage)
                    .font(Theme.mono(layout.compact ? 16 : 18, .bold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier(banner.identifier)
            }
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
                if outlineShown {
                    outline(layout: layout)
                        .frame(width: 340)
                        .frame(maxHeight: .infinity, alignment: .top)
                } else {
                    nextStep(layout: layout)
                        .frame(width: 240, alignment: .leading)
                }
            }
        } else if outlineShown {
            // The set keeps the room it needs; the outline takes the rest and
            // scrolls to the current exercise.
            VStack(alignment: .leading, spacing: layout.spacing) {
                focus(at: date, layout: layout)
                    .fixedSize(horizontal: false, vertical: true)
                outline(layout: layout)
                    .frame(minHeight: layout.compact ? 320 : 180, maxHeight: layout.compact ? 320 : .infinity)
            }
        } else {
            VStack(alignment: .leading, spacing: layout.spacing) {
                focus(at: date, layout: layout)
                    .frame(maxWidth: .infinity, maxHeight: layout.compact ? nil : .infinity)
                nextStep(layout: layout)
            }
        }
    }

    private var outlineShown: Bool { showsOutline && state.outline?.isEmpty == false }

    private func header(at date: Date) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 16) {
                workoutHeading
                Spacer(minLength: 12)
                clocks(at: date)
                sourceLabel
            }
            VStack(alignment: .leading, spacing: 6) {
                workoutHeading
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    clocks(at: date)
                    sourceLabel
                }
            }
        }
    }

    /// The time of day and, once the workout has started, its running time.
    private func clocks(at date: Date) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            if let start = state.workoutStartDate {
                let seconds = max(0, Int(date.timeIntervalSince(start)))
                Label(Self.duration(seconds), systemImage: "stopwatch")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Workout time")
                    .accessibilityValue(Self.duration(seconds))
                    .accessibilityIdentifier("ipadWorkout.workoutTime")
            }
            Text(date, format: .dateTime.hour().minute())
                .accessibilityLabel("Time")
                .accessibilityIdentifier("ipadWorkout.clock")
        }
        .font(Theme.mono(20, .bold).monospacedDigit())
        .foregroundStyle(Theme.text)
        .lineLimit(1)
    }

    static func duration(_ seconds: Int) -> String {
        let hours = seconds / 3600, minutes = seconds / 60 % 60, rest = seconds % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }

    private var workoutHeading: some View {
        Text(state.workoutName.uppercased())
            .font(Theme.display(26))
            .foregroundStyle(Theme.muted)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
    }

    private var sourceLabel: some View {
        Label(isPhoneControlled ? (controlsHere ? "LINKED TO IPHONE" : "IPHONE CONTROLS") : "THIS IPAD",
              systemImage: isPhoneControlled ? "iphone" : "ipad")
            .font(Theme.mono(12, .bold))
            .foregroundStyle(Theme.muted)
            .accessibilityLabel(isPhoneControlled
                ? (controlsHere ? "Workout linked to your iPhone, which saves each set" : "Workout controlled on iPhone")
                : "Workout controlled on this iPad")
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
            let context = targetContext(step)
            if !context.isEmpty {
                Text(context)
                    .font(Theme.mono(layout.compact || layout.tight ? 18 : 22, .bold))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
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

    /// Every exercise with its progress. On a linked iPad that sends
    /// controls, choosing one moves the iPhone's workout there.
    private func outline(layout: DisplayLayout) -> some View {
        let entries = state.outline ?? []
        let currentID = entries.first(where: \.isCurrent)?.slotID
        let nextID: String? = state.next.map(\.slotID).flatMap { $0 == currentID ? nil : $0 }
        return VStack(alignment: .leading, spacing: 10) {
            Text("WORKOUT OUTLINE")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(Theme.muted)
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(entries.enumerated()), id: \.element.slotID) { index, entry in
                            if let title = entry.groupTitle, index == 0 || entries[index - 1].groupTitle != title {
                                Text(title.uppercased())
                                    .font(Theme.mono(12, .bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.top, index == 0 ? 0 : 8)
                            }
                            outlineRow(entry, isNext: entry.slotID == nextID)
                                .id(entry.slotID)
                        }
                    }
                }
                .onAppear { if let currentID { proxy.scrollTo(currentID, anchor: .center) } }
                .onChange(of: currentID) { _, id in
                    if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } }
                }
            }
        }
        .padding(layout.compact ? 16 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ipadWorkout.outline")
    }

    @ViewBuilder
    private func outlineRow(_ entry: WorkoutDisplayState.OutlineEntry, isNext: Bool) -> some View {
        let done = entry.totalSets.map { entry.setsDone >= $0 } ?? false
        let progress = entry.isSkipped ? "SKIPPED"
            : entry.totalSets.map { "\(min(entry.setsDone, $0))/\($0)" } ?? "\(entry.setsDone)"
        let badge = entry.isCurrent ? "NOW" : isNext ? "NEXT" : nil
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: entry.isCurrent ? "arrow.right.circle.fill" : done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(entry.isCurrent ? Theme.accent : done ? Theme.done : Theme.dim)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.exerciseName)
                    .font(.headline)
                    .foregroundStyle(entry.isCurrent ? Theme.accent : entry.isSkipped ? Theme.muted : Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text((entry.isWarmup ? "Warm-up · " : "") + entry.prescription)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                if let badge {
                    Text(badge).font(Theme.mono(11, .bold)).foregroundStyle(Theme.accent)
                }
                Text(progress).font(Theme.mono(14, .bold)).monospacedDigit()
                    .foregroundStyle(done ? Theme.done : Theme.muted)
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        let value = [badge.map { $0 == "NOW" ? "Current exercise" : "Next exercise" },
                     entry.isSkipped ? "Skipped" : entry.totalSets.map { "\(min(entry.setsDone, $0)) of \($0) sets" }
                        ?? "\(entry.setsDone) sets"].compactMap { $0 }.joined(separator: ", ")
        if let onSelectOutline {
            Button { onSelectOutline(entry.slotID) } label: { row }
                .buttonStyle(.plain)
                .disabled(!outlineEnabled)
                .accessibilityLabel(entry.exerciseName)
                .accessibilityValue(value)
                .accessibilityHint("Moves your iPhone workout to this exercise")
                .accessibilityIdentifier("ipadWorkout.outline.\(entry.slotID)")
        } else {
            row
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(entry.exerciseName)
                .accessibilityValue(value)
                .accessibilityIdentifier("ipadWorkout.outline.\(entry.slotID)")
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
            let phoneOnly = isPhoneControlled && !controlsHere
            if state.timedEndDate == nil {
                return phoneOnly ? "Stop the timer on your iPhone when finished." : "Stop the timer when you are finished."
            }
            return state.timedEndDate.map { $0 <= date } == true
                ? (phoneOnly ? "Log the set on your iPhone." : "Log your completed set.")
                : "Keep going until the timer finishes."
        case .paused: return isPhoneControlled ? "Resume the workout on your iPhone." : "Resume when you are ready."
        default:
            if step.isUnilateral { return "Complete both sides, then log one set." }
            if isPhoneControlled && controlsHere { return "Complete the set, then log it below. Your iPhone saves it." }
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
        let prescription = parts.joined(separator: " × ")
        return [prescription, rpeLabel(step)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func targetContext(_ step: WorkoutDisplayState.Step) -> String {
        let bodyweight = step.isBodyweight && (step.weight ?? 0) == 0 ? "BODYWEIGHT" : nil
        return [bodyweight, rpeLabel(step)].compactMap { $0 }.joined(separator: " · ")
    }

    private func rpeLabel(_ step: WorkoutDisplayState.Step) -> String? {
        step.rpe.map { "RPE " + SetValueFormatter.number($0) }
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
