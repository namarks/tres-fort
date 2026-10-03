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
    @State private var counter = StationRepCounter(exercise: .squat)
    @State private var isCounting = false
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
                                counterPanel.frame(width: 310)
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
            isCounting = false
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            isCounting = false
            // The system permission alert temporarily makes this scene inactive.
            // Keep that request alive; actual backgrounding always cancels it.
            if phase == .inactive && camera.state == .requestingPermission { return }
            camera.stop()
            UIApplication.shared.isIdleTimerDisabled = previousIdleTimerDisabled
        }
        .onChange(of: camera.state) { _, state in
            if state != .running { isCounting = false }
            UIApplication.shared.isIdleTimerDisabled = state == .running
                ? true : previousIdleTimerDisabled
        }
        .onReceive(camera.$latestPose) { sample in
            guard isCounting else { return }
            // nil also invalidates a trial when the camera changes orientation.
            guard camera.state == .running, let sample else {
                isCounting = false
                return
            }
            counter.process(sample)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CAMERA SETUP")
                .font(Theme.display(44)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("Try camera counting before your workout.")
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
                isCounting = false
                hasRunTrial = false
                exercise = option
                counter.reset(exercise: option)
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
                isCounting = false
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
                .font(Theme.display(34)).foregroundStyle(Theme.text)
                .accessibilityIdentifier("station.movement")
            Text(String(counter.count))
                .font(Theme.number(dynamicTypeSize.isAccessibilitySize ? 70 : 112))
                .foregroundStyle(Theme.text).monospacedDigit()
                .accessibilityLabel("\(counter.count) observed reps")
                .accessibilityIdentifier("station.repCount")
            Text("REPS OBSERVED")
                .font(Theme.mono(11, .bold)).tracking(2).foregroundStyle(Theme.muted)
            Label(trackingMessage, systemImage: isCounting ? "viewfinder" : "pause.circle")
                .font(.headline).foregroundStyle(isCounting ? Theme.done : Theme.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("station.tracking")
            Divider().overlay(Theme.dim)
            Button {
                if isCounting {
                    isCounting = false
                } else {
                    counter.reset(exercise: exercise)
                    hasRunTrial = true
                    isCounting = true
                }
            } label: {
                Text(isCounting ? "Stop trial" : (hasRunTrial ? "New trial" : "Start trial"))
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
            .disabled(camera.state != .running)
            .accessibilityIdentifier("station.trial")
            Text("Trial only · No sets are saved")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("station.trialNotice")
        }
        .padding(24).frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    private var trackingMessage: String {
        if isCounting { return counter.status.message }
        if hasRunTrial { return "Trial stopped" }
        return camera.state == .running ? "Ready to try" : "Camera is off"
    }

    private var privacyNote: some View {
        Label("Video stays on this iPad. Nothing is recorded or uploaded.", systemImage: "lock.shield")
            .font(.footnote).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
