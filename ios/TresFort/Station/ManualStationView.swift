import SwiftUI

/// Public Station coordinates two independently logged phone workouts. It owns
/// no capture session, movement detector, recording store or workout writer.
struct ManualStationView: View {
    @ObservedObject var access: StationAccess
    let loadLinkKey: @MainActor () async -> Data?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var link = StationLinkStation()
    @StateObject private var partner: PartnerStationModel
    @StateObject private var idleTimer = StationIdleTimerOverride()
    @State private var linkRequest: UUID?
    @AppStorage(StationLink.stationEnabledAccountDefaultsKey) private var enabledAccount = ""
    @State private var showOptions = false
#if DEBUG && targetEnvironment(simulator)
    @State private var showLinkedDisplayFixture = false
#endif

    init(access: StationAccess, loadLinkKey: @escaping @MainActor () async -> Data?) {
        self.access = access
        self.loadLinkKey = loadLinkKey
        _partner = StateObject(wrappedValue: PartnerStationModel(accountID: access.session.accountID))
    }

    var body: some View {
        Group {
            if access.isActive {
                NavigationStack {
                    Group {
                    if showingWorkoutDisplay {
                        LinkedWorkoutDisplayView(link: link, retryConnection: { setConnection(true) }) {
                            Button("Connection & partner options", systemImage: "slider.horizontal.3") {
                                showOptions = true
                            }
                            .font(Theme.mono(16, .bold)).foregroundStyle(Theme.accent)
                            .frame(minHeight: 48)
                            .accessibilityIdentifier("ipadWorkout.options")
                        }
                    } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            if partner.isOpen {
                                PartnerStationPanel(model: partner)
                            } else {
                                setup
                            }
                        }
                        .padding(28)
                        .frame(maxWidth: 1040)
                        .frame(maxWidth: .infinity)
                    }
                    }
                    }
                    .background(Theme.background)
                    .navigationTitle("iPad Station")
                    .toolbar {
                        if showOptions && link.isEnabled {
                            ToolbarItem(placement: .topBarLeading) {
                                Button("Workout display") { showOptions = false }
                                    .accessibilityIdentifier("ipadWorkout.returnToDisplay")
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { dismiss() }.accessibilityIdentifier("station.done")
                        }
                    }
                }
            }
        }
        .onAppear {
            guard access.validate() else { dismiss(); return }
            idleTimer.begin()
            #if DEBUG && targetEnvironment(simulator)
            partner.installPublicStationUIFixtureIfRequested()
            showLinkedDisplayFixture = IpadWorkoutDisplayUIFixture.installIfRequested(
                on: link, accountID: access.session.accountID)
            #endif
            if StationLink.isEnabled(storedAccount: enabledAccount, accountID: access.session.accountID) {
                setConnection(true)
            }
            refreshIdleTimer()
        }
        .onDisappear { close() }
        .onReceive(access.$isActive) { active in
            guard !active else { return }
            close()
            dismiss()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { resumeConnection() }
            refreshIdleTimer()
        }
        .onChange(of: partner.isOpen) { _, _ in refreshIdleTimer() }
        .onChange(of: link.isEnabled) { _, _ in refreshIdleTimer() }
        .onReceive(NotificationCenter.default.publisher(for: StationLinkKeyStore.refreshed)) { note in
            guard note.userInfo?["accountID"] as? String == access.session.accountID,
                  link.isEnabled, let request = linkRequest else { return }
            Task { @MainActor in
                let key = await loadLinkKey()
                guard access.validate(), linkRequest == request, link.isEnabled, let key else { return }
                link.enable(key: key)
            }
        }
    }

    private var setup: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 12) {
                Text("IPAD STATION").font(Theme.display(44))
                    .accessibilityIdentifier("station.manualSetup")
                Text("Follow your iPhone workout from across the room, or train together with a partner. Your iPhone logs each set.")
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 20) {
                step("1", title: "Connect once",
                     detail: "Tap Connect iPhone below, then scan the setup code with your iPhone camera. Both devices must use the same Très Fort account.")
                step("2", title: "Train with your iPad display",
                     detail: "Start or resume a workout on your iPhone. Next time, just open Très Fort on your iPhone and Station on your iPad to reconnect.")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 12) {
                Button("Connect iPhone") { showOptions = false; setConnection(true) }
                    .buttonStyle(WorkoutPrimaryButtonStyle())
                    .accessibilityIdentifier("station.connectPhone")
                Toggle("Reconnect automatically", isOn: Binding(
                    get: { StationLink.isEnabled(storedAccount: enabledAccount, accountID: access.session.accountID) }, set: setConnection))
                    .tint(Theme.accent)
                    .accessibilityIdentifier("station.link")
                Text(linkMessage).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("station.linkStatus")
                Text("Training with a partner?").font(.headline)
                Text("Tap Train together, then have your partner scan the iPad code from Today → Train together on their iPhone. Start together before either person logs a set today; shared rest starts when both people finish their set.")
                    .foregroundStyle(Theme.muted)
                Button("Train together") {
                    guard access.validate() else { return }
                    partner.begin(link: link)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!link.connection.isConnected)
                .accessibilityIdentifier("station.trainTogether")
                Text("Your partner saves a copy of the shared workout, including targets and notes, to their account. Both people’s weights and progress appear on this iPad.")
                    .font(.footnote).foregroundStyle(Theme.muted)
            }
            Text("Keep your iPhone and this iPad nearby. Go online to set up and start the workout, and allow local network access when you connect.")
                .font(.footnote).foregroundStyle(Theme.muted)
        }
    }

    private func step(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Text(number).font(.title2.bold()).foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(Theme.muted)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var linkMessage: String {
        if link.needsKey { return "Go online once to set up your iPad workout display." }
        switch link.connection {
        case .off: return "Connect when your iPhone is ready."
        case .searching: return "Looking for your iPhone…"
        case .unavailable: return "Couldn’t start the local connection. Check Local Network access in Settings."
        case .connected(let name): return "Connected to \(name). Your workout appears on this iPad."
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

    /// Back in the foreground: suspension may have closed the connection,
    /// and a key that couldn't load before may load now.
    private func resumeConnection() {
        if link.needsKey { setConnection(true) } else { link.resume() }
    }

    private func refreshIdleTimer() {
        idleTimer.update(cameraRunning: false, partnerOpen: partner.isOpen,
                         foreground: scenePhase == .active && access.isActive,
                         workoutDisplay: link.isEnabled)
    }

    private var showingWorkoutDisplay: Bool {
        guard !partner.isOpen, !showOptions else { return false }
        #if DEBUG && targetEnvironment(simulator)
        if showLinkedDisplayFixture { return true }
        #endif
        return link.isEnabled || linkRequest != nil || link.needsKey
    }

    private func close() {
        idleTimer.end()
        linkRequest = nil
        partner.end()
        link.stop()
    }
}
