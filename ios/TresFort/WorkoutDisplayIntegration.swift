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
                    Text(link.connection.isConnected ? "WAITING FOR YOUR WORKOUT" : "CONNECT YOUR IPHONE")
                        .font(Theme.display(56)).foregroundStyle(Theme.text)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ipadWorkout.connection")
                    Text(link.connection.isConnected
                         ? "Open the workout on your iPhone. Both devices need a version with iPad workout display support."
                         : "On your iPhone, start a workout and turn on Use iPad workout display in Workout outline → Current exercise options. Keep the workout open on your iPhone.")
                        .font(Theme.mono(18)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    controls()
                }
                .padding(32).frame(maxWidth: 1000, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
            .background(Theme.background)
        }
    }
}
