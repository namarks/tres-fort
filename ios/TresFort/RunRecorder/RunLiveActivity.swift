import ActivityKit
import Foundation

/// The run on the Lock Screen and in the Dynamic Island
/// (docs/plans/run-recorder P2). The recorder sends its latest state; this
/// keeps one activity for the run being recorded.
@MainActor
protocol RunLiveActivityPresenting: AnyObject {
    func show(recordingID: String, state: RunActivityAttributes.ContentState)
    /// Ends every run activity, including one a lost run left behind.
    func endAll()
}

@MainActor
final class SystemRunLiveActivity: RunLiveActivityPresenting {
    private var current: Activity<RunActivityAttributes>?

    func show(recordingID: String, state: RunActivityAttributes.ContentState) {
        let content = ActivityContent(state: state, staleDate: nil)
        if current?.attributes.recordingID != recordingID {
            // ActivityKit keeps activities across an app relaunch: pick up
            // this run's and end any other run's.
            current = nil
            for activity in Activity<RunActivityAttributes>.activities {
                if activity.attributes.recordingID == recordingID, current == nil {
                    current = activity
                } else {
                    Task { await activity.end(nil, dismissalPolicy: .immediate) }
                }
            }
        }
        if let current {
            Task { await current.update(content) }
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        current = try? Activity.request(attributes: RunActivityAttributes(recordingID: recordingID),
                                        content: content)
    }

    func endAll() {
        current = nil
        for activity in Activity<RunActivityAttributes>.activities {
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
