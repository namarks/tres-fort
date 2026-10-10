import SwiftUI

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
            let state = enabled ? WorkoutDisplayState.project(sync: sync, paused: paused,
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
}

/// A linked Station never acquires the phone's writer. Disconnection removes
/// the projection, so a stale load or expired timer cannot look like guidance
/// for a live workout. Camera setup remains accessible without any count.
struct LinkedWorkoutDisplayView<Controls: View>: View {
    @ObservedObject var link: StationLinkStation
    var trackingCount: String? = nil
    var trackingStatus: String? = nil
    var retryConnection: () -> Void = {}
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        if let state = link.display {
            WorkoutDisplayView(state: state, isPhoneControlled: true,
                               trackingCount: trackingCount, trackingStatus: trackingStatus,
                               controls: controls)
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
}
