import SwiftUI
import UserNotifications

/// Opt-in workout reminders. Turning them on asks for notification permission
/// once; the time is local and applies to every workout day.
struct WorkoutReminderSettingsSection: View {
    @AppStorage(WorkoutReminderSettings.enabledKey) private var enabled = false
    @AppStorage(WorkoutReminderSettings.minutesKey) private var minutes = WorkoutReminderSettings.defaultMinutes
    @State private var permissionDenied = false
    @State private var requesting = false
    private var reminders: WorkoutReminderCoordinator { .shared }

    var body: some View {
        Section {
            Toggle("Workout reminders", isOn: Binding(get: { enabled }, set: setEnabled))
                .disabled(requesting)
                .accessibilityIdentifier("profile.reminders.toggle")
            if enabled {
                DatePicker("Remind me at", selection: time, displayedComponents: .hourAndMinute)
                    .accessibilityIdentifier("profile.reminders.time")
            }
            if permissionDenied {
                Text("Notifications are off for Très Fort. Turn them on in Settings to get reminders.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    Link("Open notification settings", destination: url)
                        .accessibilityIdentifier("profile.reminders.settings")
                }
            }
        } header: {
            Text("Reminders")
        } footer: {
            Text("A notification on each day your schedule or calendar has a workout. Rest days, skipped days and workouts you've started or finished stay quiet. Add the Très Fort widget to your Home or Lock Screen to see today's workout at a glance.")
        }
        .task { await refreshPermission() }
    }

    private var time: Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: Date())
                return calendar.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: start) ?? start
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                minutes = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
                NotificationCenter.default.post(name: WorkoutReminderSettings.changed, object: nil)
            })
    }

    private func setEnabled(_ on: Bool) {
        guard on else {
            enabled = false
            NotificationCenter.default.post(name: WorkoutReminderSettings.changed, object: nil)
            return
        }
        requesting = true
        Task { @MainActor in
            defer { requesting = false }
            let granted = await reminders.requestAuthorization()
            permissionDenied = !granted
            enabled = granted
            NotificationCenter.default.post(name: WorkoutReminderSettings.changed, object: nil)
        }
    }

    private func refreshPermission() async {
        guard enabled else { permissionDenied = false; return }
        let status = await reminders.authorizationStatus()
        permissionDenied = status == .denied
    }
}
