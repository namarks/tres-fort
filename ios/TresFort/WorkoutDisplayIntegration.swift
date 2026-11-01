import SwiftUI

extension StationLink {
    /// The signed-in account whose iPhone looks for its iPad Station, if any.
    /// Pair before starting a workout: discovery remains an account-scoped
    /// opt-in, and pairing never starts or resumes a workout by itself.
    @MainActor
    static func phoneAccount(storedAccount: String, auth: AuthModel) -> String? {
        guard isEnabled(storedAccount: storedAccount, accountID: auth.userID),
              !auth.isReviewAccount,
              UIDevice.current.userInterfaceIdiom == .phone else { return nil }
        return auth.userID
    }
}

/// The active writer publishes a complete read model even when the camera is
/// disarmed for rest, a timed set, an unsupported movement or final review.
struct StationWorkoutDisplayPublisher: View {
    @ObservedObject var sync: SyncModel
    @ObservedObject var link: StationLinkController
    let enabled: Bool
    let paused: Bool
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let state = enabled ? Self.projection(sync: sync, paused: paused,
                displayUnit: WeightUnit(rawValue: weightUnitRaw) ?? .lb) : nil
            Color.clear.frame(width: 0, height: 0)
                .task(id: state) { link.publishDisplay(state) }
                .onChange(of: link.isConnected) { _, connected in
                    // A failed key load withdrew the old projection. Publish
                    // the live runner again after Retry, even if it is idle.
                    if connected { link.publishDisplay(state) }
                }
        }
        .onDisappear { link.publishDisplay(nil) }
        .accessibilityHidden(true)
    }

    /// The projection a linked iPad shows, which also tells it that this
    /// iPhone applies the controls tapped there.
    @MainActor
    static func projection(sync: SyncModel, paused: Bool, displayUnit: WeightUnit) -> WorkoutDisplayState {
        var state = WorkoutDisplayState.project(sync: sync, paused: paused, displayUnit: displayUnit)
        state.acceptsCommands = true
        return state
    }
}

/// A linked Station never acquires the phone's writer: its controls are
/// requests the iPhone applies through its own runner, or refuses. A short
/// drop keeps the last display, marked as reconnecting and without controls;
/// a withdrawn or long-lost projection leaves the connection screen, so a
/// stale load or expired timer cannot pass for guidance on a live workout.
/// Camera setup remains accessible without any count.
struct LinkedWorkoutDisplayView<Controls: View>: View {
    @ObservedObject var link: StationLinkStation
    var trackingCount: String? = nil
    var trackingStatus: String? = nil
    var retryConnection: () -> Void = {}
    @ViewBuilder let controls: () -> Controls
    @AppStorage(StationLink.outlineShownDefaultsKey) private var showsOutline = true
    @State private var editing: LinkedSetDraft?

    var body: some View {
        if let state = link.display {
            let remote = state.acceptsCommands == true
            let ready = link.acceptsCommands && link.pendingCommand == nil
            WorkoutDisplayView(state: state, isPhoneControlled: true, controlsHere: remote,
                               trackingCount: trackingCount, trackingStatus: trackingStatus,
                               showsOutline: showsOutline, banner: banner,
                               onSelectOutline: remote ? { _ = link.send(.select(slotID: $0), for: state.current) } : nil,
                               outlineEnabled: ready && state.phase.offersExerciseChoice) {
                LinkedWorkoutControls(state: state, remote: remote, ready: ready,
                                      showsOutline: $showsOutline,
                                      edit: { editing = LinkedSetDraft(step: $0) },
                                      send: { _ = link.send($0, for: $1) },
                                      extra: controls)
            }
            .sheet(item: $editing) { draft in
                let step = draft.step
                SetValuesEditor(title: "Next set", values: SetCorrectionValues(
                    weight: step.weight ?? 0, reps: step.reps ?? step.durationSeconds ?? 0, rpe: step.rpe,
                    durationSeconds: step.durationSeconds),
                    timed: step.durationSeconds != nil, allowsAssistance: step.isBodyweight,
                    storedUnit: step.weightUnit, unilateral: step.isUnilateral,
                    onSave: { values in link.send(.setValues(values, unit: step.weightUnit), for: step) })
            }
            // Edits belong to the set on screen; close them when it changes
            // or the controls go away.
            .onChange(of: state.current) { _, _ in editing = nil }
            .onChange(of: link.acceptsCommands) { _, accepts in if !accepts { editing = nil } }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.system(size: 42)).foregroundStyle(Theme.accent)
                    Text(link.connection.isConnected ? "IPHONE CONNECTED" : "CONNECT YOUR IPHONE")
                        .font(Theme.display(56)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ipadWorkout.connection")
                    Text(link.connection.isConnected
                         ? "Start or resume a workout on your iPhone. It will appear here automatically."
                         : "Keep Très Fort open on your iPhone. If you’ve connected before, your workout will appear automatically.")
                        .font(Theme.mono(18)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    if !link.connection.isConnected {
                        if link.needsKey {
                            Text("Connect this iPad to the internet to finish setup, then try again.")
                                .accessibilityIdentifier("station.connectionProblem")
                        } else if link.connection == .unavailable {
                            Text("Couldn’t start the local connection. Check Local Network access in Settings, then try again.")
                                .accessibilityIdentifier("station.connectionProblem")
                        }
                        StationSetupCode()
                        Button("Try again", action: retryConnection)
                            .font(Theme.mono(16, .bold)).foregroundStyle(Theme.accent)
                            .frame(minHeight: 48)
                            .accessibilityIdentifier("station.retryConnection")
                        StationConnectionHelp()
                    }
                    controls()
                }
                .padding(32).frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.background)
        }
    }

    private var banner: WorkoutDisplayBanner? {
        if link.displayIsStale {
            return WorkoutDisplayBanner(
                text: "Reconnecting to your iPhone. Keep Très Fort open on it; controls return when it’s back.",
                systemImage: "antenna.radiowaves.left.and.right.slash", identifier: "ipadWorkout.reconnecting")
        }
        if let notice = link.commandNotice {
            return WorkoutDisplayBanner(text: notice, systemImage: "exclamationmark.circle",
                                        identifier: "ipadWorkout.notice")
        }
        return nil
    }
}

private struct LinkedSetDraft: Identifiable {
    let id = UUID()
    let step: WorkoutDisplayState.Step
}

/// The iPad's workout controls, laid out like the iPad's own runner. Each one
/// asks the iPhone to act on the set shown; nothing here logs a set.
private struct LinkedWorkoutControls<Extra: View>: View {
    let state: WorkoutDisplayState
    /// The iPhone applies controls; an older one only shows its workout here.
    let remote: Bool
    /// Connected, current and with no control still unanswered.
    let ready: Bool
    @Binding var showsOutline: Bool
    let edit: (WorkoutDisplayState.Step) -> Void
    let send: (StationLinkCommand.Action, WorkoutDisplayState.Step?) -> Void
    let extra: () -> Extra

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if remote, let step = editableStep {
                    Button { edit(step) } label: {
                        Label("Edit set", systemImage: "slider.horizontal.3")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("runner.editValues")
                    .disabled(!ready)
                }
                if state.outline?.isEmpty == false {
                    Button { showsOutline.toggle() } label: {
                        Label(showsOutline ? "Hide outline" : "Workout outline", systemImage: "list.bullet")
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("ipadWorkout.outlineToggle")
                }
                extra()
            }
            .font(Theme.mono(14, .bold)).foregroundStyle(Theme.accent)
            if remote { setControls }
        }
    }

    /// The values of a set that hasn't started can change; a running timer's can't.
    private var editableStep: WorkoutDisplayState.Step? {
        state.phase == .ready || state.phase == .rest ? state.current : nil
    }

    @ViewBuilder
    private var setControls: some View {
        // A reserved row keeps the logging action in place as rest starts and
        // ends, so a second tap on End rest never becomes a set submission.
        if state.phase == .rest {
            Button { send(.endRest, state.current) } label: {
                Text("END REST").font(Theme.mono(16, .bold))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(Theme.accent).foregroundStyle(Theme.bg)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityIdentifier("rest.done")
        } else {
            Spacer(minLength: 0).frame(height: 44)
        }
        if state.phase == .active, let step = state.current {
            Button { send(.stopTimer, step) } label: {
                Text("STOP & LOG").font(Theme.display(24)).tracking(1.2)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .background(Theme.surface2).foregroundStyle(Theme.text)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .buttonStyle(.plain)
            .disabled(!ready)
            .accessibilityIdentifier("runner.stopTimedSet")
        } else if state.phase == .ready || state.phase == .rest, let step = state.current {
            let resting = state.phase == .rest
            let timed = step.durationSeconds != nil
            Button { send(timed ? .startTimer : .logSet, step) } label: {
                Text(timed ? "START SET \(step.setNumber)" : "LOG SET \(step.setNumber)")
                    .font(Theme.display(timed ? 24 : 26)).tracking(1.2)
                    .frame(maxWidth: .infinity).padding(.vertical, 16)
                    .contentShape(Rectangle())
            }
            .background(resting ? Theme.surface2 : Theme.accent)
            .foregroundStyle(resting ? Theme.accent : Theme.onAccent)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.accent.opacity(resting ? 0.6 : 0), lineWidth: 1))
            .buttonStyle(.plain)
            // End rest first, as on this iPad's own runner.
            .disabled(!ready || resting)
            .opacity(ready ? 1 : 0.55)
            .accessibilityIdentifier(timed ? "runner.startSet" : "runner.logSet")
        } else if state.phase == .exerciseComplete {
            Text("EXERCISE COMPLETE")
                .font(Theme.display(24)).tracking(1.2)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .foregroundStyle(Theme.done)
                .accessibilityIdentifier("runner.exerciseComplete")
        }
    }
}
