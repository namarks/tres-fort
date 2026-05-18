import SwiftUI

@main
struct LiftCoachApp: App {
    @StateObject private var model = AuthModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
