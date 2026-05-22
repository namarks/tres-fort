import SwiftUI

@main
struct TresForteApp: App {
    @StateObject private var model = AuthModel()

    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(model)
        }
    }
}
