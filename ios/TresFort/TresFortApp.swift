import SwiftUI

@main
struct TresFortApp: App {
    @StateObject private var model = AuthModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
