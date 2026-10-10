import SwiftUI
import Combine

/// The entry owns one immutable account/epoch capability for this presentation.
/// AuthModel is reduced to a validator and boundary registration at the caller.
struct StationEntryView: View {
    let workoutName: String?
    let workout: [StationExerciseOption]
    let catalog: [StationExerciseOption]
    let loadLinkKey: @MainActor () async -> Data?
    @StateObject private var access: StationAccess

    init(workoutName: String?, workout: [StationExerciseOption] = [], catalog: [StationExerciseOption] = [],
         accountID: String?, epoch: UInt64,
         isCurrentSession: @escaping @MainActor () -> Bool,
         observeBoundary: @escaping (@escaping () -> Bool) -> Void,
         loadLinkKey: @escaping @MainActor () async -> Data? = { nil }) {
        self.workoutName = workoutName
        self.workout = workout
        self.catalog = catalog
        self.loadLinkKey = loadLinkKey
        _access = StateObject(wrappedValue: StationAccess(accountID: accountID, epoch: epoch,
                                                       isCurrentSession: isCurrentSession,
                                                       observeBoundary: observeBoundary))
    }

    var body: some View {
        #if APP_STORE_BUILD
        ManualStationView(access: access, loadLinkKey: loadLinkKey)
        #else
        StationView(workoutName: workoutName, workout: workout, catalog: catalog, access: access,
                    loadLinkKey: loadLinkKey)
        #endif
    }
}

#if !APP_STORE_BUILD
/// An observation-only trial. This view receives immutable display values and a
/// link key loader, never a SyncModel, API client, outbox or binding to the
/// workout's mutable state.
struct StationView: View {
    let workoutName: String?
    let workout: [StationExerciseOption]
    let catalog: [StationExerciseOption]
    @ObservedObject var access: StationAccess
    let loadLinkKey: @MainActor () async -> Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @StateObject private var camera: StationCamera
    @State private var exercise: StationExercise = .squat
    @State private var trialMode: StationTrialMode? = .squat
    @State private var selectedOption: StationExerciseOption?
    @State private var holdTimer = StationHoldTimer(kind: .plank, targetSeconds: 30)
    @State private var showCatalog = false
    @StateObject private var comparison = StationLiveModel()
    /// Optional link that counts the set armed by this account's iPhone runner.
    /// It carries counts out; nothing here can log a set.
    @StateObject private var link = StationLinkStation()
    @StateObject private var partner: PartnerStationModel
    @State private var linkedArmID: UUID?
    /// The latest "on" tap; turning the link off or on again supersedes it.
    @State private var linkRequest: UUID?
    @AppStorage(StationLink.stationEnabledAccountDefaultsKey) private var enabledAccount = ""
#if DEBUG
    @StateObject private var diagnostics = StationDiagnostics()
#endif
    @State private var actualReps = ""
    @FocusState private var actualRepsFocused: Bool
    @State private var hasRunTrial = false
    @StateObject private var idleTimer = StationIdleTimerOverride()
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var showSavedTests = false
    @State private var showStationSetup = false
#if DEBUG && targetEnvironment(simulator)
    @State private var showLinkedDisplayFixture = false
#endif

    init(workoutName: String?, workout: [StationExerciseOption] = [], catalog: [StationExerciseOption] = [],
         access: StationAccess, loadLinkKey: @escaping @MainActor () async -> Data? = { nil }) {
        self.workoutName = workoutName
        self.workout = workout
        self.catalog = catalog
        self.access = access
        self.loadLinkKey = loadLinkKey
        _partner = StateObject(wrappedValue: PartnerStationModel(accountID: access.session.accountID))
        _camera = StateObject(wrappedValue: StationCamera(access: access))
    }

    var body: some View {
        Group {
        if access.isActive {
        NavigationStack {
            Group {
            if showingWorkoutDisplay {
                LinkedWorkoutDisplayView(link: link, trackingCount: linkedCount,
                    trackingStatus: linkedTrackingStatus, retryConnection: { setConnection(true) }) {
                    Button("Camera & options", systemImage: "slider.horizontal.3") {
                        showStationSetup = true
                    }
                    .font(Theme.mono(16, .bold)).foregroundStyle(Theme.accent)
                    .frame(minHeight: 48)
                    .accessibilityIdentifier("ipadWorkout.options")
                }
            } else {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        if partner.isOpen {
                            PartnerStationPanel(model: partner)
                        } else {
                        heading
                        linkPanel
                        exercisePicker
                        if let selectedOption { mappingDetails(selectedOption) }
                        if trialMode != nil {
                        if geometry.size.width >= 850 && !dynamicTypeSize.isAccessibilitySize {
                            HStack(alignment: .top, spacing: 24) {
                                cameraPanel.frame(maxWidth: .infinity)
                                trackingPanel.frame(width: 400)
                            }
                        } else {
                            trackingPanel
                            cameraPanel
                        }
                        if trialMode?.repExercise != nil { recordingPanel }
#if DEBUG
                        if trialMode?.repExercise != nil { diagnosticPanel }
#endif
                        } else {
                            // Manual-only selection: the link stays reachable, and an
                            // armed iPhone set switches to its rep counter.
                            Text("This movement uses manual logging on your iPhone.")
                                .foregroundStyle(Theme.muted)
                        }
                        Button("Train together") {
                            guard !recordingBusy, access.validate() else { return }
                            cancelCountdown(); cancelComparison("Starting partner workout.")
                            camera.stop(); holdTimer.invalidate(); linkedArmID = nil
                            partner.begin(link: link)
                        }.buttonStyle(.borderedProminent)
                            .disabled(!link.connection.isConnected || recordingBusy)
                            .accessibilityIdentifier("station.trainTogether")
                        privacyNote
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1240)
                    .frame(maxWidth: .infinity)
                }
                .background(Theme.background)
            }
            }
            }
            .navigationTitle("Station Mode")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showStationSetup && link.isEnabled {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Workout display") { showStationSetup = false }
                            .accessibilityIdentifier("ipadWorkout.returnToDisplay")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("station.done")
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        } else {
            ContentUnavailableView("Account session ended", systemImage: "lock")
        }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            idleTimer.begin()
            refreshIdleTimer()
            if !access.validate() { dismiss() }
            #if DEBUG && targetEnvironment(simulator)
            showLinkedDisplayFixture = IpadWorkoutDisplayUIFixture.installIfRequested(
                on: link, accountID: access.session.accountID)
            #endif
            if StationLink.isEnabled(storedAccount: enabledAccount, accountID: access.session.accountID) {
                setConnection(true)
            }
        }
        .onReceive(access.$isActive) { active in
            guard !active else { return }
            idleTimer.end()
            partner.end()
            cancelCountdown()
            linkRequest = nil
            link.stop()
            linkedArmID = nil
            comparison.reset(exercise: exercise)
            holdTimer = StationHoldTimer(kind: holdTimer.kind, targetSeconds: 30)
            selectedOption = nil
            showCatalog = false
            actualReps = ""
            hasRunTrial = false
            showSavedTests = false
            camera.stop()
            dismiss()
        }
        .onDisappear {
            idleTimer.end()
            partner.end()
            cancelCountdown()
            linkRequest = nil
            link.stop()
#if DEBUG
            diagnostics.isEnabled = false
#endif
            cancelComparison("Camera closed. Results cover only part of this trial.")
            camera.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { refreshIdleTimer(); return }
            cancelCountdown()
            cancelComparison("Tracking stopped when the app became inactive.")
            // The system permission alert temporarily makes this scene inactive.
            // Keep that request alive; actual backgrounding always cancels it.
            if phase == .inactive && camera.state == .requestingPermission { return }
            camera.stop()
            refreshIdleTimer()
        }
        .onChange(of: camera.state) { _, state in
            if state != .running {
                cancelCountdown()
                cancelComparison("Camera stopped. Results cover only part of this trial.")
            } else if let arm = link.armToCount, linkedArmID != arm.armID {
                startLinkedTrial(arm)
            }
            refreshIdleTimer()
        }
        .onChange(of: partner.isOpen) { _, _ in refreshIdleTimer() }
        .onChange(of: link.isEnabled) { _, _ in refreshIdleTimer() }
        // A rotated key restarts advertising so the iPhone can find it again.
        .onReceive(NotificationCenter.default.publisher(for: StationLinkKeyStore.refreshed)) { _ in
            guard link.isEnabled, let request = linkRequest else { return }
            Task { @MainActor in
                let key = await loadLinkKey()
                guard access.validate(), linkRequest == request, link.isEnabled, let key else { return }
                link.enable(key: key)
            }
        }
        .onReceive(camera.$latestFrame) { frame in
            guard access.validate() else { return }
            if comparison.state.isCollecting {
                if camera.state == .running, let frame {
                    comparison.process(frame)
                    observeLinkedTrial(at: frame.sample.timestamp)
                }
                else { cancelComparison("Camera view changed. Start a new test.") }
            }
            if holdTimer.isActive {
                if camera.state == .running, let frame, frame.detector == .mediaPipe {
                    holdTimer.process(frame.sample)
                } else { holdTimer.invalidate() }
            }
#if DEBUG
            if trialMode?.repExercise != nil {
                diagnostics.observeLive(frame: frame, snapshot: comparison.diagnosticSnapshot)
            }
#endif
        }
        .onChange(of: camera.recordingState) { previous, current in
            // Saving may take time while preview frames keep arriving. End the
            // recorded trial at capture stop, not after file finalization.
            if case .recording = previous {
                if case .recording = current { return }
                comparison.stop()
            }
        }
        .sheet(isPresented: $showSavedTests) { StationRecordingsView(access: access) }
        .sheet(isPresented: $showCatalog) {
            StationCatalogView(workout: workout, catalog: catalog) { option in
                choose(option.trial(), option: option)
            }
        }
        .onChange(of: link.arm) { _, arm in handleArm(arm) }
        .onChange(of: comparison.state) { _, state in
            // Stopped by hand or invalidated before the set settled: offer
            // what was counted as partial, so it never logs without a tap.
            guard linkedArmID != nil, link.isCounting, state.isTerminal else { return }
            // Nothing was counted: the same arm may be retried with Start
            // tracking or by turning the camera back on.
            if !link.trialEnded(count: comparison.count, leftCount: comparison.leftCount,
                                rightCount: comparison.rightCount, partial: true) {
                linkedArmID = nil
            }
        }
    }

    private func refreshIdleTimer() {
        idleTimer.update(cameraRunning: camera.state == .running, partnerOpen: partner.isOpen,
                         foreground: scenePhase == .active && access.isActive,
                         workoutDisplay: link.isEnabled)
    }

    private var showingWorkoutDisplay: Bool {
        guard !partner.isOpen, !showStationSetup else { return false }
        #if DEBUG && targetEnvironment(simulator)
        if showLinkedDisplayFixture { return true }
        #endif
        return link.isEnabled || linkRequest != nil || link.needsKey
    }

    private var linkedCount: String? {
        guard link.isCounting else { return nil }
        if exercise == .curl {
            let left = comparison.leftCount.map { String($0) } ?? "—"
            let right = comparison.rightCount.map { String($0) } ?? "—"
            return "L \(left) · R \(right)"
        }
        return "\(comparison.count)"
    }

    private var linkedTrackingStatus: String? {
        guard camera.state == .running else { return "Camera off · Log sets on your iPhone" }
        guard link.isCounting else { return "Your iPhone controls logging and progression" }
        return comparison.hasIncompleteCoverage ? "Tracking interrupted · Review the count on your iPhone"
            : comparison.status.message
    }

    private func handleArm(_ arm: StationLinkArm?) {
        guard !partner.isOpen else { return }
        if let current = linkedArmID, current != arm?.armID {
            linkedArmID = nil
            if comparison.state.isCollecting { comparison.reset(exercise: exercise) }
        }
        guard let arm else { return }
        // Show the armed set's counter even before the camera is on, so a hold
        // or manual-only selection never hides the way to count it.
        if link.armToCount?.armID == arm.armID, !recordingBusy, !comparison.state.isCollecting {
            adoptArmedExercise(arm)
        }
        startLinkedTrial(arm)
    }

    /// The iPhone's armed set decides the movement: a hold or catalog selection
    /// on this iPad gives way to that set's rep counter.
    private func adoptArmedExercise(_ arm: StationLinkArm) {
        holdTimer.invalidate()
        trialMode = StationTrialMode(rawValue: arm.exercise.rawValue)
        selectedOption = nil
        exercise = arm.exercise
    }

    private func startLinkedTrial(_ arm: StationLinkArm) {
        guard !partner.isOpen, access.validate(), link.armToCount?.armID == arm.armID, linkedArmID != arm.armID else { return }
        guard camera.state == .running, !recordingBusy, !showSavedTests else {
            link.report(camera.state == .running ? .stopped : .cameraOff, armID: arm.armID)
            return
        }
        actualRepsFocused = false
        actualReps = ""
        adoptArmedExercise(arm)
        hasRunTrial = true
        linkedArmID = arm.armID
        comparison.start(exercise: arm.exercise)
        link.beginCounting()
    }

    private func observeLinkedTrial(at timestamp: TimeInterval) {
        guard linkedArmID != nil, link.isCounting, comparison.state.isCollecting else { return }
        let finished = link.observe(count: comparison.count, leftCount: comparison.leftCount,
                                    rightCount: comparison.rightCount, status: comparison.status,
                                    partial: comparison.hasIncompleteCoverage, at: timestamp)
        if finished { comparison.stop() }
    }

    private var linkPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("IPHONE WORKOUT DISPLAY").font(Theme.mono(12, .bold))
            Button("Connect iPhone") {
                showStationSetup = false
                setConnection(true)
            }
            .buttonStyle(WorkoutPrimaryButtonStyle())
            .accessibilityIdentifier("station.connectPhone")
            Toggle("Reconnect automatically", isOn: Binding(
                get: { StationLink.isEnabled(storedAccount: enabledAccount, accountID: access.session.accountID) },
                set: setConnection))
                .tint(Theme.accent).accessibilityIdentifier("station.link")
            Text(linkMessage)
                .font(.subheadline).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("station.linkStatus")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18))
    }

    private var linkMessage: String {
        if link.needsKey {
            return "Connect this iPad to the internet once to finish setup, then try again."
        }
        switch link.connection {
        case .off:
            return "Connect once, then open Station whenever you want to use your iPad display."
        case .searching:
            return "Looking for your iPhone. Open Très Fort on it, or scan the setup code."
        case .unavailable:
            return "Couldn’t start the local connection. Check Local Network access in Settings."
        case .connected(let name):
            guard let arm = link.arm else { return "Connected to \(name). Waiting for your next set." }
            let state = link.isCounting ? "Counting"
                : link.manualArmID == arm.armID ? "Log this set on your iPhone"
                : linkedArmID == arm.armID ? "Sent to your iPhone"
                : camera.state == .running ? "Not counting" : "Turn on the camera to count"
            return "Connected to \(name) · \(arm.exerciseName), set \(arm.setNumber) · \(state)"
        }
    }

    private func setConnection(_ enabled: Bool) {
        guard access.validate() else { return }
        enabledAccount = enabled ? access.session.accountID : ""
        linkRequest = nil
        link.stop()
        guard enabled else { return }
        let request = UUID()
        linkRequest = request
        Task { @MainActor in
            let key = await loadLinkKey()
            guard access.validate(), linkRequest == request else { return }
            link.enable(key: key)
            if !link.isEnabled { linkRequest = nil }
        }
    }

    private func cancelComparison(_ reason: String) {
        holdTimer.invalidate()
        if comparison.state.isCollecting {
            comparison.invalidate(reason: reason)
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MOVEMENT TRACKING")
                .font(Theme.display(44)).foregroundStyle(Theme.text)
                .accessibilityAddTraits(.isHeader)
            Text("MediaPipe tracks your movement live. Compare Apple and MediaPipe on the same recording in Saved tests.")
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
            HStack {
                ForEach([StationTrialMode.plank, .wallSit]) { mode in
                    Button(mode.title) { choose(mode) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("station.exercise.\(mode.rawValue)")
                }
            }
            .disabled(recordingBusy)
            Button("Choose from workout or catalog", systemImage: "list.bullet") {
                cancelComparison("Tracking stopped to choose an exercise.")
                camera.stop()
                showCatalog = true
            }
            .disabled(recordingBusy)
            .accessibilityIdentifier("station.catalog")
        }
    }

    @ViewBuilder private var exerciseButtons: some View {
        ForEach(StationExercise.allCases) { option in
            Button {
                choose(StationTrialMode(rawValue: option.rawValue))
            } label: {
                Text(option.title)
                    .font(.headline)
                    .padding(.horizontal, 24).frame(minHeight: 52)
                    .foregroundStyle(trialMode?.repExercise == option ? Theme.bg : Theme.text)
                    .background(trialMode?.repExercise == option ? Theme.accent : Theme.surface2,
                                in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(trialMode?.repExercise == option ? [.isSelected] : [])
            .accessibilityIdentifier("station.exercise.\(option.rawValue)")
            .disabled(recordingBusy)
        }
    }

    private func choose(_ mode: StationTrialMode?, option: StationExerciseOption? = nil) {
        // Taking over by hand ends the armed set here, counted or not,
        // so the camera or Start tracking can't silently re-link it.
        link.abandon()
        cancelComparison("Exercise changed. Start a new test.")
        trialMode = mode
        selectedOption = option
        hasRunTrial = false
        actualReps = ""
        actualRepsFocused = false
        if let rep = mode?.repExercise { exercise = rep }
        comparison.reset(exercise: exercise)
        holdTimer = StationHoldTimer(kind: mode?.holdKind ?? .plank, targetSeconds: option?.targetSeconds ?? 30)
    }

    @ViewBuilder private var trackingPanel: some View {
        if trialMode?.holdKind != nil {
            StationHoldPanel(timer: $holdTimer, cameraRunning: camera.state == .running,
                             title: selectedOption?.name ?? holdTimer.kind.title)
                .id(selectedOption?.id ?? trialMode?.rawValue)
        } else { counterPanel }
    }

    private func mappingDetails(_ option: StationExerciseOption) -> some View {
        let entry = StationTrackingCatalog.bundled.entry(for: option.exerciseID)
        return VStack(alignment: .leading, spacing: 8) {
            Text(option.name).font(.title2.bold())
            Text(trialMode == nil && entry.trial != nil ? "Use the workout timer for this prescription" : entry.status)
                .font(.headline).accessibilityIdentifier("station.catalogStatus")
            if let profile = entry.profile {
                Text("\(profile.title) · \(profile.measurement == .hold ? "Seconds in position" : "Movement repetitions")")
                Text(profile.cameraView)
                Text(profile.definition)
                Text(profile.limitation).foregroundStyle(Theme.muted)
            }
            if let reason = entry.reason { Text(reason).foregroundStyle(Theme.muted) }
            if trialMode == nil {
                Text("Continue with manual logging or the workout timer. Camera tracking is not enabled for this selection.")
            }
        }
        .font(.subheadline).padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 16))
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
                Text(trialMode?.holdKind != nil ? holdTimer.state.message :
                     StationPoseFeedback(sample: camera.latestPose, exercise: exercise).message)
                    .font(.headline).foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("station.poseFeedback")
                Text("Green joints are clear. Orange joints need a better view.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }

            Text(trialMode?.holdKind?.guidance ?? exercise.guidance)
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
            Text((selectedOption?.name ?? exercise.title).uppercased())
                .font(Theme.display(30)).foregroundStyle(Theme.text)
                .accessibilityIdentifier("station.movement")
            if exercise == .curl {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 12) { curlCountTiles }
                } else {
                    HStack(alignment: .top, spacing: 12) { curlCountTiles }
                }
                Text("Each arm is counted separately. Left and right refer to your body.")
                    .font(.caption).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
            } else {
                countTile(title: "MediaPipe", value: String(comparison.count),
                          detail: comparison.state.isCollecting ? comparison.status.message : "Complete movement cycles",
                          identifier: "station.repCount", spokenValue: "MediaPipe: \(comparison.count) reps")
            }
            Text(comparison.state.message)
                .font(.headline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("station.tracking")
            if comparison.state.isCollecting {
                Text("Start in the extended position, then complete the movement.")
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
            Button {
                actualRepsFocused = false
                if comparison.state.isCollecting {
                    comparison.stop()
                } else if let arm = link.armToCount, linkedArmID == nil {
                    startLinkedTrial(arm)
                } else {
                    actualReps = ""
                    hasRunTrial = true
                    comparison.start(exercise: exercise)
                }
            } label: {
                Text(comparison.state.isCollecting ? "Stop tracking" :
                     hasRunTrial ? "New tracking test" : "Start tracking")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.borderedProminent).tint(Theme.accent).foregroundStyle(Theme.bg)
            .disabled(camera.state != .running || recordingBusy)
            .accessibilityIdentifier("station.trial")

            if hasRunTrial && comparison.state.isTerminal {
                if exercise == .curl {
                    Text("For a recorded test, enter the actual count for each arm in Saved tests.")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                } else { referenceCount }
            }
            if hasRunTrial { timingDetails }
            Text(link.isEnabled ? "This iPad saves nothing · Your iPhone logs the set" : "Trial only · No sets are saved")
                .font(.subheadline).foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .accessibilityIdentifier("station.trialNotice")
        }
        .padding(20).frame(maxWidth: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder private var curlCountTiles: some View {
        countTile(title: "Left arm", value: String(comparison.leftCount ?? 0),
                  detail: comparison.state.isCollecting ? (comparison.leftStatus?.message ?? "Step into view") : "MediaPipe",
                  identifier: "station.leftRepCount", spokenValue: "Left arm: \(comparison.leftCount ?? 0) reps")
        countTile(title: "Right arm", value: String(comparison.rightCount ?? 0),
                  detail: comparison.state.isCollecting ? (comparison.rightStatus?.message ?? "Step into view") : "MediaPipe",
                  identifier: "station.rightRepCount", spokenValue: "Right arm: \(comparison.rightCount ?? 0) reps")
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
                Text("MediaPipe difference: \(comparison.count - actual, specifier: "%+d")")
                    .accessibilityIdentifier("station.customDifference")
                if comparison.hasIncompleteCoverage || comparison.state != .finished {
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
                Text("Camera poses: \(comparison.observedFrames)")
                if let fps = comparison.observedFPS {
                    Text("Observed pose rate: \(fps, specifier: "%.1f") fps")
                }
                if let duration = comparison.inferenceMilliseconds {
                    Text("Latest MediaPipe inference: \(duration, specifier: "%.0f") ms")
                }
                Text("Inference includes orientation and pose tracking. It is not full camera-to-screen latency.")
                    .foregroundStyle(Theme.muted)
            }
            .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
        }
        .font(.subheadline).foregroundStyle(Theme.text)
        .accessibilityIdentifier("station.timing")
    }

    private var privacyNote: some View {
        Label("Live video is not saved unless you choose Record test. Saved tests stay on this iPad until you share or delete them. No automatic uploads.", systemImage: "lock.shield")
            .font(.footnote).foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var recordingBusy: Bool {
        if countdown != nil { return true }
        switch camera.recordingState {
        case .recording, .finishing: return true
        default: return false
        }
    }

    private var recordingPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("REPEATABLE CAMERA TEST").font(Theme.mono(12, .bold))
            Text("Record up to 45 seconds of silent video and tracking measurements. Try front-facing and sideways squats in separate tests, then save the actual count for each.")
                .font(.subheadline).foregroundStyle(Theme.muted)
            if let countdown {
                Text("Recording starts in \(countdown)…").font(.title.bold()).monospacedDigit()
                Button("Cancel countdown") { cancelCountdown() }
            } else {
                switch camera.recordingState {
                case .recording(let elapsed):
                    Text("Recording · \(elapsed, specifier: "%.0f") / 45 seconds")
                        .font(.title2.bold()).foregroundStyle(.red).monospacedDigit()
                    Button("Stop and save test", systemImage: "stop.circle.fill") { camera.stopRecording() }
                        .buttonStyle(.borderedProminent)
                case .finishing:
                    ProgressView("Saving test…")
                case .saved:
                    Label("Test saved on this iPad", systemImage: "checkmark.circle")
                    recordButton
                case .failed(let message):
                    Text(message).foregroundStyle(.red)
                    recordButton
                case .idle:
                    recordButton
                }
            }
            Button("Saved tests · compare and share", systemImage: "rectangle.stack") {
                cancelCountdown()
                cancelComparison("Camera stopped to review saved tests.")
                camera.stop()
                showSavedTests = true
            }
            .disabled(recordingBusy)
            .accessibilityIdentifier("station.savedTests")
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 18))
    }

    private var recordButton: some View {
        Button("Record test", systemImage: "record.circle") {
            cancelComparison("Starting a new recorded test.")
            countdown = 5
            let selectedExercise = exercise
            countdownTask = Task { @MainActor in
                do {
                    for remaining in (1...5).reversed() {
                        countdown = remaining
                        try await Task.sleep(for: .seconds(1))
                    }
                    guard !Task.isCancelled, camera.state == .running, scenePhase == .active else {
                        countdown = nil
                        return
                    }
                    countdown = nil
                    hasRunTrial = true
                    actualReps = ""
                    comparison.start(exercise: selectedExercise)
                    camera.startRecording(exercise: selectedExercise)
                } catch { }
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(camera.state != .running)
        .accessibilityIdentifier("station.recordTest")
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

#if DEBUG
    private var diagnosticPanel: some View {
        DisclosureGroup("Developer diagnostics") {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Stream tracking measurements", isOn: $diagnostics.isEnabled)
                    .accessibilityIdentifier("station.diagnosticsEnabled")
                Text("While enabled, joint measurements and counting decisions stream to the connected Mac. Camera images are never included. Recent measurements stay in memory for up to one minute.")
                    .font(.caption).foregroundStyle(Theme.muted)
                if diagnostics.isEnabled {
                    Text(diagnostics.latestSummary)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("station.diagnosticsSummary")
                    Button("Clear measurements") { diagnostics.clear() }
                        .accessibilityIdentifier("station.clearDiagnostics")
                }
            }
            .padding(.top, 12)
        }
        .font(.subheadline).foregroundStyle(Theme.text)
        .accessibilityIdentifier("station.diagnostics")
    }
#endif
}

#endif

/// Camera and manual partner mode share one override, so stopping the camera
/// cannot release the screen while Station still coordinates both phones.
@MainActor
final class StationIdleTimerOverride: ObservableObject {
    private let read: () -> Bool
    private let write: (Bool) -> Void
    private var previous: Bool?

    init(read: @escaping () -> Bool = { UIApplication.shared.isIdleTimerDisabled },
         write: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.read = read
        self.write = write
    }
    func begin() {
        if previous == nil { previous = read() }
    }
    func update(cameraRunning: Bool, partnerOpen: Bool, foreground: Bool, workoutDisplay: Bool = false) {
        guard let previous else { return }
        write(foreground && (cameraRunning || partnerOpen || workoutDisplay) ? true : previous)
    }
    func end() {
        guard let previous else { return }
        self.previous = nil
        write(previous)
    }
}
