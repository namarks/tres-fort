import SwiftUI

/// The strap on the recorder's start screen: what's connected and its live
/// reading, or a way to set one up.
struct HeartRateStatusRow: View {
    @ObservedObject var monitor: HeartRateMonitor
    var onSetUp: () -> Void

    var body: some View {
        Button(action: onSetUp) {
            HStack {
                Label(monitor.status, systemImage: monitor.isConnected ? "heart.fill" : "heart")
                    .foregroundStyle(monitor.isConnected ? Theme.accent : Theme.muted)
                Spacer()
                Text(monitor.saved == nil ? "Set up" : "Change")
                    .foregroundStyle(Theme.accent)
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("runRecorder.heartRate.status")
    }
}

/// Finds Bluetooth heart rate straps nearby and remembers the one picked.
/// No pairing in iOS Settings: the strap connects here.
struct HeartRateMonitorSetupView: View {
    @ObservedObject var monitor: HeartRateMonitor
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let saved = monitor.saved {
                    Section("Your monitor") {
                        HStack {
                            Label(saved.name, systemImage: monitor.isConnected ? "heart.fill" : "heart")
                            Spacer()
                            Text(connection).foregroundStyle(.secondary)
                        }
                        .accessibilityIdentifier("heartRate.saved")
                        Button("Forget this monitor", role: .destructive) { monitor.forget() }
                            .accessibilityIdentifier("heartRate.forget")
                    }
                }
                Section {
                    if let problem = bluetoothProblem {
                        Text(problem).foregroundStyle(.secondary)
                    } else if nearby.isEmpty {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text("Looking for heart rate monitors…").foregroundStyle(.secondary)
                        }
                    }
                    ForEach(nearby) { strap in
                        Button {
                            monitor.choose(strap)
                        } label: {
                            Label(strap.name, systemImage: "heart")
                        }
                        .accessibilityIdentifier("heartRate.found")
                    }
                } header: {
                    Text(monitor.saved == nil ? "Nearby" : "Use a different monitor")
                }
                Section("Tips") {
                    Text("Put the strap on and wet its sensor pads. Most straps turn on when they touch skin.")
                    Text("Bluetooth straps such as Polar, Wahoo and Garmin HRM work. You don’t need to pair them in iOS Settings.")
                    Text("Some watches can broadcast heart rate over Bluetooth from their settings. Ones that broadcast only over ANT+ won’t show up, because iPhone can’t receive ANT+.")
                }
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            .navigationTitle("Heart rate monitor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("heartRate.done")
                }
            }
        }
        .onAppear { monitor.startSearching() }
        .onDisappear { monitor.stopSearching() }
    }

    /// Found straps other than the saved one.
    private var nearby: [HeartRateMonitor.Strap] {
        monitor.found.filter { $0.id != monitor.saved?.id }
    }

    private var connection: String {
        guard monitor.isConnected else { return "Not connected" }
        guard let latest = monitor.latest else { return "Connected" }
        return "\(Int(latest.beatsPerMinute.rounded())) bpm"
    }

    private var bluetoothProblem: String? {
        switch monitor.bluetooth {
        case .off: "Turn on Bluetooth in Control Center or Settings to find your monitor."
        case .denied: "Allow Bluetooth for Très Fort in Settings to connect a heart rate monitor."
        case .unsupported: "This iPhone can’t use Bluetooth heart rate monitors."
        case .unknown, .on: nil
        }
    }
}
