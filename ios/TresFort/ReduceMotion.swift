import SwiftUI

/// The system Reduce Motion setting as the app honors it. Debug simulator
/// builds also turn it on when a UI test launches with
/// `TRESFORT_UI_REDUCE_MOTION=1`, so tests never drive Apple's Settings app,
/// whose layout and speed vary between iOS releases and loaded CI simulators.
/// Read it with `@ReduceMotion private var reduceMotion`.
@propertyWrapper
struct ReduceMotion: DynamicProperty {
    @Environment(\.accessibilityReduceMotion) private var system

    init() {}

    var wrappedValue: Bool { system || Self.requestedByUITest }

    static let requestedByUITest: Bool = {
        #if DEBUG && targetEnvironment(simulator)
        ProcessInfo.processInfo.environment["TRESFORT_UI_REDUCE_MOTION"] == "1"
        #else
        false
        #endif
    }()
}
