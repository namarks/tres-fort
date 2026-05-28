import ActivityKit
import Foundation

// App-side controller. Local Live Activity: we only ever set an endDate and
// let the system render the countdown — no APNs / push token in v1.
enum RestLiveActivity {
    private static var current: Activity<RestActivityAttributes>?

    static func start(exercise: String, endDate: Date, upNext: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        endNow()
        let attributes = RestActivityAttributes(exercise: exercise)
        let state = RestActivityAttributes.ContentState(endDate: endDate, upNext: upNext)
        current = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: endDate.addingTimeInterval(120)))
    }

    static func update(endDate: Date, upNext: String) {
        guard let activity = current else { return }
        let state = RestActivityAttributes.ContentState(endDate: endDate, upNext: upNext)
        Task { await activity.update(.init(state: state, staleDate: endDate.addingTimeInterval(120))) }
    }

    static func endNow() {
        guard let activity = current else { return }
        current = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }
}
