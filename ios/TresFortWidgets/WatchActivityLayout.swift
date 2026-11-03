import ActivityKit
import SwiftUI
import WidgetKit

// Live Activities started on the iPhone also show in a paired Apple Watch's
// Smart Stack (iOS 18 with watchOS 11 and later). Without the small family
// the Watch shrinks the Dynamic Island's compact views; declaring it lets each
// activity draw its own wrist layout. Buttons there run the same intents on
// the iPhone. iOS 17 keeps the Lock Screen and Dynamic Island unchanged.

extension WidgetConfiguration {
    /// Adds the small family that the Apple Watch Smart Stack draws, where the
    /// system supports it.
    func watchSmartStackFamily() -> some WidgetConfiguration {
        if #available(iOS 18.0, *) {
            return supplementalActivityFamilies([.small])
        } else {
            return self
        }
    }
}

/// Shows `wrist` when the system draws the activity in the small family (the
/// Apple Watch Smart Stack), else `standard`, the Lock Screen layout.
struct ActivityFamilyLayout<Wrist: View, Standard: View>: View {
    @ViewBuilder let wrist: () -> Wrist
    @ViewBuilder let standard: () -> Standard

    var body: some View {
        if #available(iOS 18.0, *) {
            ActivityFamilySwitch(wrist: wrist, standard: standard)
        } else {
            standard()
        }
    }
}

@available(iOS 18.0, *)
private struct ActivityFamilySwitch<Wrist: View, Standard: View>: View {
    @Environment(\.activityFamily) private var family
    let wrist: () -> Wrist
    let standard: () -> Standard

    var body: some View {
        switch family {
        case .small:
            wrist()
        default:
            standard()
        }
    }
}
