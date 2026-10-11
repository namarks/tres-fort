import Combine
import Foundation
import UIKit
import UserNotifications
import WidgetKit

// The return loop (member-activation P1): a Today widget and opt-in local
// workout reminders. Both read one display snapshot built from the SAME
// calendar projection Today and the calendar use, so there is no second
// schedule algorithm and no server notification system. Account boundaries
// clear both, because the widget and pending notifications are process-shared.

extension SyncModel {
    /// Civil days covered by the widget timeline and the reminder horizon.
    static let trainingAgendaDayCount = 14

    /// Today and the following days as the projection resolves them now.
    /// nil until a plan has been read, so a cold launch never replaces a good
    /// snapshot with an empty "rest" week.
    func trainingAgendaSnapshot(dayCount: Int = SyncModel.trainingAgendaDayCount) -> TrainingAgendaSnapshot? {
        guard plan != nil, dayCount > 0 else { return nil }
        // Single clock for the whole scan, as in `upcomingDays`.
        let today = todayString
        guard let start = CalendarProjection.date(from: today) else { return nil }
        var days: [TrainingAgendaDay] = []
        for offset in 0..<dayCount {
            guard let date = CalendarProjection.calendar.date(byAdding: .day, value: offset, to: start) else { continue }
            days.append(trainingAgendaDay(for: CalendarProjection.dateString(date), today: today))
        }
        return TrainingAgendaSnapshot(days: days)
    }

    private func trainingAgendaDay(for ymd: String, today: String) -> TrainingAgendaDay {
        let resolved = projection(for: ymd, today: today)
        // A started runner can name an explicit workout before its first set
        // creates a session, including one chosen on a rest day: the mounted
        // runner's own selection, or a resumable checkpoint after relaunch.
        if ymd == today, resolved.kind != .completed, resolved.kind != .skipped,
           let started = running ? selectedDay : resumableCheckpoint.flatMap({
               $0.date == today ? workout(id: $0.selectedDayID) : nil
           }) {
            return agendaDay(ymd, .inProgress, started)
        }
        switch resolved {
        case .projected(let templateID):
            return agendaDay(ymd, .workout, workout(id: templateID))
        case .session(let status, _):
            let preview = previewWorkout(forDateString: ymd, today: today)
            let freestyle = sessionsByDate[ymd]?.isFreestyle == true
            switch status {
            case "completed":
                return agendaDay(ymd, .completed, preview, freestyle: freestyle)
            case "skipped":
                return agendaDay(ymd, .skipped, nil)
            case "in_progress":
                // A phantom in-progress row (every set deleted) is still the
                // planned workout, exactly as Today presents it.
                let started = loggedSetCount(forDate: ymd) > 0
                return agendaDay(ymd, started ? .inProgress : .workout, preview, freestyle: freestyle)
            default:
                return agendaDay(ymd, .workout, preview, freestyle: freestyle)
            }
        case .rest, .none:
            return agendaDay(ymd, .rest, nil)
        case .unavailable:
            return agendaDay(ymd, .unavailable, nil)
        case .light:
            return agendaDay(ymd, .light, nil)
        }
    }

    private func agendaDay(_ ymd: String, _ status: TrainingAgendaDay.Status, _ workout: Workout?,
                           freestyle: Bool = false) -> TrainingAgendaDay {
        var seen = Set<String>()
        let names = (workout?.exercises ?? [])
            .filter { !$0.isWarmup }
            .map(\.exercise_name)
            .filter { seen.insert($0).inserted }
        return TrainingAgendaDay(
            date: ymd, status: status,
            workoutName: workout?.name ?? (freestyle ? "Freestyle workout" : nil),
            exerciseNames: names)
    }
}

// MARK: - Reminder settings and plan

enum WorkoutReminderSettings {
    static let enabledKey = "workoutRemindersEnabled"
    static let minutesKey = "workoutReminderMinutes"
    /// 7:00 in the morning, local time.
    static let defaultMinutes = 7 * 60
    static let changed = Notification.Name("com.nmarkspdx.tresfort.workout-reminder-settings")

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: enabledKey)
    }

    static func minutesAfterMidnight(_ defaults: UserDefaults = .standard) -> Int {
        guard defaults.object(forKey: minutesKey) != nil else { return defaultMinutes }
        return min(max(defaults.integer(forKey: minutesKey), 0), 24 * 60 - 1)
    }
}

struct WorkoutReminder: Equatable {
    let id: String
    let date: String
    let fireComponents: DateComponents
    let title: String
    let body: String
}

enum WorkoutReminderPlan {
    static let idPrefix = "workout-reminder-"

    static func isReminderID(_ identifier: String) -> Bool { identifier.hasPrefix(idPrefix) }

    /// One reminder per day that still has a workout to start, at the chosen
    /// local time. Rest, skipped, trip, started and finished days stay quiet,
    /// and a time already past today is not scheduled.
    static func reminders(snapshot: TrainingAgendaSnapshot, now: Date, minutesAfterMidnight: Int,
                          calendar: Calendar) -> [WorkoutReminder] {
        snapshot.days.compactMap { day -> WorkoutReminder? in
            guard day.status == .workout,
                  let start = TrainingAgendaCalendar.date(from: day.date, calendar: calendar),
                  let fire = calendar.date(bySettingHour: minutesAfterMidnight / 60,
                                           minute: minutesAfterMidnight % 60, second: 0, of: start),
                  fire > now
            else { return nil }
            return WorkoutReminder(
                id: idPrefix + day.date,
                date: day.date,
                fireComponents: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fire),
                title: "Today: \(day.workoutName ?? "Workout")",
                body: body(for: day))
        }
    }

    static func body(for day: TrainingAgendaDay) -> String {
        let names = day.exerciseNames
        guard !names.isEmpty else { return "Your workout is ready in Très Fort." }
        let shown = names.prefix(3).joined(separator: " · ")
        return names.count > 3 ? "\(shown) + \(names.count - 3) more" : shown
    }
}

// MARK: - Notification center

@MainActor
protocol WorkoutReminderCenter: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func pendingIdentifiers() async -> [String]
    func deliveredIdentifiers() async -> [String]
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
final class SystemWorkoutReminderCenter: WorkoutReminderCenter {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
    }

    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }

    func pendingIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func removePending(_ identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(_ identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Owns the reminder identifiers. Applications run one after another, and a
/// superseded one stops at its next await, so a stale agenda can never leave
/// its reminders behind a newer replacement or a sign-out.
@MainActor
final class WorkoutReminderCoordinator {
    static let shared = WorkoutReminderCoordinator(center: SystemWorkoutReminderCenter())

    private let center: any WorkoutReminderCenter
    private var generation = 0
    private var task: Task<Void, Never>?

    init(center: any WorkoutReminderCenter) { self.center = center }

    /// Replace every pending reminder with `reminders`. A delivered reminder
    /// stays in Notification Center only while its date is in `keepDelivered`.
    func apply(_ reminders: [WorkoutReminder], keepDelivered: Set<String> = []) {
        generation &+= 1
        let token = generation
        let previous = task
        task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, token == self.generation else { return }
            let pending = await self.center.pendingIdentifiers()
            let delivered = await self.center.deliveredIdentifiers()
            guard token == self.generation else { return }
            self.center.removePending(pending.filter(WorkoutReminderPlan.isReminderID))
            self.center.removeDelivered(delivered.filter {
                WorkoutReminderPlan.isReminderID($0)
                    && !keepDelivered.contains(String($0.dropFirst(WorkoutReminderPlan.idPrefix.count)))
            })
            guard !reminders.isEmpty else { return }
            let status = await self.center.authorizationStatus()
            guard token == self.generation, [.authorized, .provisional, .ephemeral].contains(status) else { return }
            for reminder in reminders {
                guard token == self.generation else { return }
                try? await self.center.add(WorkoutReminderCoordinator.request(for: reminder))
            }
        }
    }

    func clear() { apply([]) }

    func requestAuthorization() async -> Bool {
        switch await center.authorizationStatus() {
        case .authorized, .provisional, .ephemeral: return true
        case .notDetermined: return await center.requestAuthorization()
        default: return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus { await center.authorizationStatus() }

    func waitForTests() async { await task?.value }

    static func request(for reminder: WorkoutReminder) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = reminder.title
        content.body = reminder.body
        content.sound = .default
        content.userInfo = ["date": reminder.date]
        let trigger = UNCalendarNotificationTrigger(dateMatching: reminder.fireComponents, repeats: false)
        return UNNotificationRequest(identifier: reminder.id, content: content, trigger: trigger)
    }
}

// MARK: - Publisher

/// Writes the widget snapshot and reschedules reminders after each published
/// plan/session change, a reminder-setting change, and a new civil day. One is
/// owned by each signed-in tab shell; the feature-session boundary retires it
/// and clears what it published.
@MainActor
final class TrainingAgendaPublisher {
    private struct ReminderInput: Equatable {
        let snapshot: TrainingAgendaSnapshot
        let enabled: Bool
        let minutes: Int
    }

    private weak var sync: SyncModel?
    private let sharedDefaults: UserDefaults?
    private let settings: UserDefaults
    private let reminders: WorkoutReminderCoordinator
    private let reloadWidgets: () -> Void
    private let now: () -> Date
    private var cancellables: Set<AnyCancellable> = []
    private var lastReminderInput: ReminderInput?
    private(set) var isRetired = false

    init(sync: SyncModel, auth: AuthModel,
         sharedDefaults: UserDefaults? = TrainingAgendaStore.sharedDefaults,
         settings: UserDefaults = .standard,
         reminders: WorkoutReminderCoordinator = .shared,
         reloadWidgets: @escaping () -> Void = {
             WidgetCenter.shared.reloadTimelines(ofKind: TrainingAgendaStore.widgetKind)
         },
         now: @escaping () -> Date = Date.init,
         notificationCenter: NotificationCenter = .default) {
        self.sync = sync
        self.sharedDefaults = sharedDefaults
        self.settings = settings
        self.reminders = reminders
        self.reloadWidgets = reloadWidgets
        self.now = now
        // objectWillChange fires before the mutation lands; read on the next
        // main-actor turn. Throttle so a running rest timer cannot rebuild the
        // snapshot every tick.
        sync.objectWillChange
            .throttle(for: .seconds(1), scheduler: RunLoop.main, latest: true)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
            .store(in: &cancellables)
        for name in [WorkoutReminderSettings.changed, .NSCalendarDayChanged] {
            notificationCenter.publisher(for: name)
                .sink { [weak self] _ in Task { @MainActor in self?.refresh() } }
                .store(in: &cancellables)
        }
        // The widget timeline holds absolute midnights computed in the zone it
        // was built in, so a new zone needs a rebuilt timeline even when the
        // snapshot is unchanged.
        notificationCenter.publisher(for: .NSSystemTimeZoneDidChange)
            .sink { [weak self] _ in Task { @MainActor in self?.refresh(forceWidgetReload: true) } }
            .store(in: &cancellables)
        // Notification permission can change in Settings while the agenda does
        // not, and the zone can change while the app is not running. Reapply
        // reminders and rebuild the timeline on each return.
        notificationCenter.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                Task { @MainActor in self?.refresh(reapplyReminders: true, forceWidgetReload: true) }
            }
            .store(in: &cancellables)
        auth.observeFeatureSessionBoundary { [weak self] in
            self?.retire()
            return false
        }
        Task { @MainActor [weak self] in self?.refresh() }
    }

    func refresh(reapplyReminders: Bool = false, forceWidgetReload: Bool = false) {
        guard !isRetired, let sync, sync.canPublishTrainingAgenda,
              let snapshot = sync.trainingAgendaSnapshot()
        else { return }
        let changed = TrainingAgendaStore.save(snapshot, to: sharedDefaults)
        if changed || forceWidgetReload { reloadWidgets() }
        let input = ReminderInput(
            snapshot: snapshot,
            enabled: WorkoutReminderSettings.isEnabled(settings),
            minutes: WorkoutReminderSettings.minutesAfterMidnight(settings))
        guard reapplyReminders || input != lastReminderInput else { return }
        lastReminderInput = input
        guard input.enabled else {
            reminders.clear()
            return
        }
        // Today's delivered reminder stays visible until the workout starts.
        let keep = snapshot.days.first.flatMap { $0.status == .workout ? $0.date : nil }
        reminders.apply(
            WorkoutReminderPlan.reminders(snapshot: snapshot, now: now(),
                                          minutesAfterMidnight: input.minutes,
                                          calendar: TrainingAgendaCalendar.calendar()),
            keepDelivered: Set([keep].compactMap { $0 }))
    }

    /// The account is leaving: nothing it published may stay on the Home
    /// Screen, Lock Screen or in pending notifications.
    func retire() {
        guard !isRetired else { return }
        isRetired = true
        cancellables = []
        lastReminderInput = nil
        if TrainingAgendaStore.save(nil, to: sharedDefaults) { reloadWidgets() }
        reminders.clear()
    }
}
