import ActivityKit
import Foundation

// Shared between the app (starts/updates/ends the Activity) and the widget
// extension (renders it on the Lock Screen / Dynamic Island). Compiled into
// BOTH targets — lives in ios/Shared.
struct RestActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var endDate: Date     // Text(timerInterval:) counts down to this — no push needed
        var upNext: String
    }
    var exercise: String      // the lift you just finished a set of
}
