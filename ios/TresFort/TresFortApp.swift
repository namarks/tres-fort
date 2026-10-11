import SwiftUI
import UserNotifications

@main
struct TresFortApp: App {
    @UIApplicationDelegateAdaptor(TresFortAppDelegate.self) private var appDelegate
    @StateObject private var model: AuthModel

    init() {
#if DEBUG && targetEnvironment(simulator)
        if UIFixtureScenario.selected != nil {
            _model = StateObject(wrappedValue: UIFixtureModel.makeAuth())
            return
        }
#endif
        _model = StateObject(wrappedValue: AuthModel())
    }

    var body: some Scene {
        WindowGroup {
#if DEBUG && targetEnvironment(simulator)
            if let scenario = UIFixtureScenario.selected {
                UIFixtureView(auth: model, scenario: scenario)
            } else {
                RootView().environmentObject(model)
            }
#else
            RootView().environmentObject(model)
#endif
        }
    }
}

final class TresFortAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Installed before launch finishes so a reminder that cold-launches
        // the app is still routed.
        UNUserNotificationCenter.current().delegate = WorkoutReminderNotificationDelegate.shared
        return true
    }
}

/// Routes a tapped workout reminder to Today. It deliberately does not
/// implement `willPresent`, so foreground notifications stay suppressed: the
/// rest cue relies on a delivered notification meaning the app was not active
/// at its deadline.
final class WorkoutReminderNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WorkoutReminderNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        DispatchQueue.main.async {
            if WorkoutReminderPlan.isReminderID(identifier) {
                NotificationCenter.default.post(name: TrainingAgendaLink.openToday, object: nil)
            }
            completionHandler()
        }
    }
}
