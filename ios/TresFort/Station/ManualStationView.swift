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

    init(access: StationAccess, loadLinkKey: @escaping @MainActor () async -> Data?) {
        self.access = access
        self.loadLinkKey = loadLinkKey
        _partner = StateObject(wrappedValue: PartnerStationModel(accountID: access.session.accountID))
    }

    var body: some View {
        Group {
            if access.isActive {
                NavigationStack {
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
                    .background(Theme.background)
                    .navigationTitle("iPad Station")
                    .toolbar {
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
            #endif
            refreshIdleTimer()
        }
        .onDisappear { close() }
        .onReceive(access.$isActive) { active in
            guard !active else { return }
            close()
            dismiss()
        }
        .onChange(of: scenePhase) { _, _ in refreshIdleTimer() }
        .onChange(of: partner.isOpen) { _, _ in refreshIdleTimer() }
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
                Text("Train together").font(.largeTitle.bold())
                    .accessibilityIdentifier("station.manualSetup")
                Text("Use this iPad as your shared workout display. Each person logs sets on their own iPhone.")
                    .font(.title2)
            }
            VStack(alignment: .leading, spacing: 20) {
                step("1", title: "Connect the host’s iPhone",
                     detail: "Sign in to the same account on this iPad and the host’s iPhone. On the iPhone, start a workout, open Workout outline → Current exercise options, and turn on Use iPad for partner workout.")
                step("2", title: "Invite your partner",
                     detail: "Connect below, then tap Train together. Your partner uses their own account and scans the iPad code from Today → Train together on their iPhone.")
                step("3", title: "Lift together, log separately",
                     detail: "Review each person’s weights on their iPhone. Start together on the iPad before either person logs a set or completes a workout today. The shared rest starts when both people finish their set.")
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface2, in: RoundedRectangle(cornerRadius: 20))
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Connect host’s iPhone", isOn: Binding(
                    get: { link.isEnabled || linkRequest != nil }, set: setConnection))
                    .tint(Theme.accent)
                    .accessibilityIdentifier("station.link")
                Text(linkMessage).foregroundStyle(Theme.muted)
                    .accessibilityIdentifier("station.linkStatus")
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
            Text("Keep both iPhones and this iPad nearby. Go online to set up and start the workout, and allow local network access when you connect. Each person can continue alone on their iPhone.")
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
        if link.needsKey { return "Go online once to set up partner training on this iPad." }
        switch link.connection {
        case .off: return "Connect when your host’s iPhone is ready."
        case .searching: return "Looking for your host’s iPhone…"
        case .connected(let name): return "Connected to \(name). Ready to invite your partner."
        }
    }

    private func setConnection(_ enabled: Bool) {
        guard enabled else { linkRequest = nil; link.stop(); return }
        guard access.validate() else { return }
        let request = UUID()
        linkRequest = request
        Task { @MainActor in
            let key = await loadLinkKey()
            guard access.validate(), linkRequest == request else { return }
            link.enable(key: key)
            if !link.isEnabled { linkRequest = nil }
        }
    }

    private func refreshIdleTimer() {
        idleTimer.update(cameraRunning: false, partnerOpen: partner.isOpen,
                         foreground: scenePhase == .active && access.isActive)
    }

    private func close() {
        idleTimer.end()
        linkRequest = nil
        partner.end()
        link.stop()
    }
}
