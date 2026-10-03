import SwiftUI
import Combine

/// An observation-only trial. This view receives a display string, never a
/// SyncModel, API client, outbox or binding to the workout's mutable state.
struct StationView: View {
    let workoutName: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var camera = StationCamera()
    @State private var exercise: StationExercise = .squat
    @StateObject private var comparison = StationComparisonModel()
    @State private var actualReps = ""
    @FocusState private var actualRepsFocused: Bool
    @State private var hasRunTrial = false
    @State private var previousIdleTimerDisabled = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        heading
                        exercisePicker
                        if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 24) {
                                cameraPanel.frame(maxWidth: .infinity)
                                counterPanel.frame(width: 400)
                            }
                        } else {
                            counterPanel
                            cameraPanel
                        }
                        privacyNote
                    }
                    .padding(24)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.background)
            }
            .navigationTitle("Station Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("station.done")
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .onAppear { previousIdleTimerDisabled = UIApplication.shared.isIdleTimerDisabled }
        .onDisappear {
            cancelComparison("Camera closed. Results cover only part of this trial.")
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            cancelComparison("Comparison stopped when the app became inactive.")
            // The system permission alert temporarily makes this scene inactive.
            // Keep that request alive; actual backgrounding always cancels it.
            if phase == .inactive && camera.state == .requestingPermission { return }
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: camera.state) { _, state in
            if state != .running {
                cancelComparison("Camera stopped. Results cover only part of this trial.")
            }
            UIApplication.shared.isIdleTimerDisabled = state == .running
                ? true : previousIdleTimerDisabled
        }
        .onReceive(camera.$latestFrame) { frame in
            guard comparison.state.isCollecting else { return }
            guard camera.state == .running, let frame else {
                cancelComparison("Camera view changed. Start a new comparison.")
                return
            }
            comparison.process(frame)
        }
    }

    private func cancelComparison(_ reason: String) {
        if comparison.state.isCollecting || comparison.state.isFinishing {
            comparison.invalidate(reason: reason)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("COMPARE COUNTERS")
                .font(Theme.display(44)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("One camera. The same movements. Two independent counts.")
                .font(.title3).foregroundStyle(Theme.muted)
            if let workoutName {
                Text("Today's workout · \(workoutName)")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
        }
    }

    private var exercisePicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CHOOSE A MOVEMENT")
                .font(Theme.mono(11, .bold)).foregroundStyle(Theme.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { exerciseButtons }
                VStack(alignment: .leading, spacing: 12) { exerciseButtons }
            }
        }
    }

    @ViewBuilder private var exerciseButtons: some View {
        ForEach(StationExercise.allCases) { option in
            Button {
                hasRunTrial = false
                actualReps = ""
                actualRepsFocused = false
                exercise = option
                comparison.reset(exercise: option)
            } label: {
                Text(option.title)
                    .font(.headline)
                    .padding(.horizontal, 24).frame(minHeight: 52)
                    .foregroundStyle(exercise == option ? Theme.bg : Theme.text)
                    .background(exercise == option ? Theme.accent : Theme.surface2,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(exercise == option ? [.isSelected] : [])
            .accessibilityIdentifier("station.exercise.\(option.rawValue)")
        }
    }

    private var cameraPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            cameraControls
            ZStack {
                Color.black
                if camera.state == .running {
                    StationCameraPreview(session: camera.session)
                        .overlay { StationPoseOverlay(frame: camera.latestFrame) }
                } else {
                    VStack(spacing: 14) {
                        Image(systemName: "viewfinder")
                            .font(.system(size: 54, weight: .ultraLight))
                            .foregroundStyle(Theme.accent)
                            .accessibilityHidden(true)
                        Text(camera.state.message)
                            .font(.headline).multilineTextAlignment(.center)
                            .foregroundStyle(Theme.text)
                            .accessibilityIdentifier("station.cameraStatus")
                        if camera.state == .idle {
                            Text("Face the screen and leave room for your full movement.")
                                .font(.subheadline).foregroundStyle(Theme.muted)
                                .multilineTextAlignment(.center)
                        }
                    }.padding(24)
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 320 : 280)
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Camera setup")

            if camera.state == .running {
                Text(camera.framingDescription)
                    .font(.subheadline.bold()).foregroundStyle(Theme.text)
                    .accessibilityIdentifier("station.framing")
                Text(StationPoseFeedback(sample: camera.latestPose, exercise: exercise).message)
                    .font(.headline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("station.poseFeedback")
                Text("Green joints are clear. Orange joints need a better view.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            Text(exercise.guidance)
                .font(.body).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            Text("Keep the iPad still, use good lighting, and stay alone in view. Camera counts are estimates.")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var cameraControls: some View {
        if camera.state == .running {
            Button("Turn camera off", systemImage: "video.slash") {
                cancelComparison("Camera turned off. Results cover only part of this trial.")
                camera.stop()
            }
            .frame(minHeight: 48)
            .accessibilityIdentifier("station.cameraOff")
        } else if camera.state == .denied {
            Button("Open camera settings", systemImage: "gearshape") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .frame(minHeight: 48)
        } else {
            Button {
                camera.start()
            } label: {
                Label("Enable camera", systemImage: "video")
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent)
            .foregroundStyle(Theme.bg)
            .disabled(camera.state == .requestingPermission)
            .accessibilityIdentifier("station.enableCamera")
        }
    }

    private var counterPanel: some View {
        VStack(spacing: 16) {
            Text(exercise.title.uppercased())
                .font(Theme.display(30)).foregroundStyle(Theme.text)
                .accessibilityIdentifier("station.movement")
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 16) { countTiles }
            } else {
                HStack(alignment: .top, spacing: 12) { countTiles }
            }
            Text(comparison.state.message)
                .font(.headline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("station.tracking")
            if comparison.state.isCollecting {
                Text(comparison.readinessMessage)
                    .font(.subheadline).foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("station.readiness")
            }
            if comparison.hasIncompleteCoverage {
                Text("Tracking was interrupted. These counts cover only the movements we could see.")
                    .font(.subheadline).foregroundStyle(.orange)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("station.partialCoverage")
            }
            if comparison.state == .warmingUp {
                ProgressView(value: Double(comparison.metrics.windowProgress),
                             total: Double(comparison.metrics.windowFrames))
                    .tint(Theme.accent)
                    .accessibilityLabel("Apple counter warm-up")
            }
            Button {
                actualRepsFocused = false
                if comparison.state.isCollecting {
                    comparison.stop()
                } else {
                    actualReps = ""
                    hasRunTrial = true
                    comparison.start(exercise: exercise)
                }
            } label: {
                Text(comparison.state.isFinishing ? "Finishing Apple…" :
                     comparison.state.isCollecting ? "Stop comparison" :
                     hasRunTrial ? "New comparison" : "Start comparison")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
            .disabled(camera.state != .running || comparison.state.isFinishing)
            .accessibilityIdentifier("station.trial")

            if hasRunTrial && comparison.state.isTerminal { referenceCount }
            if hasRunTrial { timingDetails }
            Text("Trial only · No sets are saved")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("station.trialNotice")
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var countTiles: some View {
        countTile(title: "Custom", value: String(comparison.customCount),
                  detail: comparison.state.isCollecting ? comparison.customStatus.message : "Complete movement cycles", identifier: "station.repCount",
                  spokenValue: "Custom counter: \(comparison.customCount) reps")
        countTile(title: "Apple estimate", value: comparison.appleCount.map { String(format: "%.1f", $0) } ?? "—",
                  detail: "May update later", identifier: "station.appleCount",
                  spokenValue: comparison.appleCount.map { String(format: "Apple estimate: %.1f reps", $0) }
                    ?? "Apple estimate: awaiting result")
    }

    private func countTile(title: String, value: String, detail: String,
                           identifier: String, spokenValue: String) -> some View {
        VStack(spacing: 8) {
            Text(title).font(.headline).foregroundStyle(Theme.text)
            Text(value)
                .font(Theme.number(54)).monospacedDigit()
                .foregroundStyle(Theme.text)
                .lineLimit(1).minimumScaleFactor(0.5)
                .accessibilityLabel(spokenValue)
                .accessibilityIdentifier(identifier)
            Text(detail).font(.caption).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 12)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 14))
    }

    private var referenceCount: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("How many reps did you do?").font(.headline)
            TextField("Actual reps", text: $actualReps)
                .keyboardType(.numberPad).textFieldStyle(.roundedBorder)
                .focused($actualRepsFocused)
                .accessibilityIdentifier("station.actualReps")
                .onChange(of: actualReps) { _, value in
                    let digits = String(value.filter { $0.isASCII && $0.isNumber }.prefix(3))
                    if value != digits { actualReps = digits }
                }
            if let actual = Int(actualReps) {
                Text("Custom difference: \(comparison.customCount - actual, specifier: "%+d")")
                    .accessibilityIdentifier("station.customDifference")
                if let apple = comparison.appleCount {
                    Text("Apple difference: \(Double(apple) - Double(actual), specifier: "%+.1f")")
                        .accessibilityIdentifier("station.appleDifference")
                }
                if comparison.state != .finished {
                    Text("This trial is incomplete. Differences include unobserved movement.")
                        .foregroundStyle(Theme.muted)
                }
            }
            if actualRepsFocused {
                Button("Done entering count") { actualRepsFocused = false }
            }
        }
        .font(.subheadline).foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timingDetails: some View {
        DisclosureGroup("Timing and coverage") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Same input: \(comparison.metrics.acceptedFrames) poses")
                Text("Apple coverage: \(comparison.metrics.appleCoveredFrames) poses")
                if let fps = comparison.metrics.acceptedFPS {
                    Text("Observed pose rate: \(fps, specifier: "%.1f") fps")
                }
                if let lag = comparison.metrics.appleSourceLagSeconds {
                    Text("Apple coverage behind input: \(lag, specifier: "%.1f") s")
                }
                if let duration = comparison.metrics.appleProcessingMilliseconds {
                    Text("Latest Apple analysis: \(duration, specifier: "%.0f") ms")
                }
                Text("Coverage delay measures how far Apple's result trails the incoming poses. It is not a measurement of full camera-to-screen latency.")
                    .foregroundStyle(Theme.muted)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.subheadline).foregroundStyle(Theme.text)
        .accessibilityIdentifier("station.timing")
    }

    private var privacyNote: some View {
        Label("Video stays on this iPad. Nothing is recorded or uploaded.", systemImage: "lock.shield")
            .font(.footnote).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
