import AVFoundation
import AudioToolbox
import UIKit
import UserNotifications

@MainActor
protocol RestNotificationCenterProviding: AnyObject {
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization(options: UNAuthorizationOptions) async throws -> Bool
    func add(_ request: UNNotificationRequest) async throws
    func pendingNotificationIdentifiers() async -> [String]
    func deliveredNotificationIdentifiers() async -> [String]
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

@MainActor
private final class SystemRestNotificationCenter: RestNotificationCenterProviding {
    private let center = UNUserNotificationCenter.current()

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    func requestAuthorization(
        options: UNAuthorizationOptions
    ) async throws -> Bool {
        try await center.requestAuthorization(options: options)
    }

    func add(_ request: UNNotificationRequest) async throws {
        try await center.add(request)
    }

    func pendingNotificationIdentifiers() async -> [String] {
        await center.pendingNotificationRequests().map(\.identifier)
    }

    func deliveredNotificationIdentifiers() async -> [String] {
        await center.deliveredNotifications().map { $0.request.identifier }
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }
}

/// Owns every mutation of the single rest-notification slot on the main actor.
/// Each scheduled request receives a unique identifier, so a stale async add
/// can remove only itself after a newer schedule/cancel advances `generation`.
@MainActor
final class RestNotificationCoordinator {
    private static let legacyNotificationID = "rest-cue"
    private static let notificationPrefix = "rest-cue-"

    private let center: any RestNotificationCenterProviding
    private let now: () -> Date
    private let requestIDFactory: () -> String
    private var generation = 0
    private var activeRequestID: String?
    private var scheduleTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?

    init(
        center: any RestNotificationCenterProviding,
        now: @escaping () -> Date = Date.init,
        requestIDFactory: @escaping () -> String = {
            UUID().uuidString.lowercased()
        }
    ) {
        self.center = center
        self.now = now
        self.requestIDFactory = requestIDFactory
    }

    func requestPermissionIfNeeded() async {
        guard await center.authorizationStatus() == .notDetermined else {
            return
        }
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    func schedule(at end: Date) {
        generation &+= 1
        let token = generation
        let requestID = Self.notificationPrefix + requestIDFactory()
        if let activeRequestID {
            center.removePendingNotificationRequests(
                withIdentifiers: [activeRequestID])
            center.removeDeliveredNotifications(
                withIdentifiers: [activeRequestID])
        }
        activeRequestID = nil

        scheduleTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let status = await center.authorizationStatus()
            guard token == generation,
                  [.authorized, .provisional, .ephemeral].contains(status)
            else { return }

            // Clear requests left by a previous process before installing the
            // current unique id. A superseding schedule/cancel invalidates this
            // cleanup before it can touch newer work.
            let pending = await center.pendingNotificationIdentifiers()
            let delivered = await center.deliveredNotificationIdentifiers()
            guard token == generation else { return }
            removeRestNotifications(
                pending: pending, delivered: delivered)

            let content = UNMutableNotificationContent()
            content.title = "Rest's up"
            content.body = "Time for your next set."
            content.sound = .default
            content.interruptionLevel = .timeSensitive
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(end.timeIntervalSince(now()), 1),
                repeats: false)
            let request = UNNotificationRequest(
                identifier: requestID, content: content, trigger: trigger)
            do {
                try await center.add(request)
            } catch {
                return
            }
            guard token == generation else {
                // Cancellation may have run while `add` was suspended. The
                // unique id prevents this cleanup from deleting a newer cue.
                center.removePendingNotificationRequests(
                    withIdentifiers: [requestID])
                center.removeDeliveredNotifications(
                    withIdentifiers: [requestID])
                return
            }
            activeRequestID = requestID
        }
    }

    func notificationWasDelivered() async -> Bool {
        let delivered = await center.deliveredNotificationIdentifiers()
        return delivered.contains(where: Self.isRestNotification)
    }

    func cancel() {
        generation &+= 1
        let token = generation
        let knownIDs = [activeRequestID, Self.legacyNotificationID].compactMap { $0 }
        activeRequestID = nil
        center.removePendingNotificationRequests(withIdentifiers: knownIDs)
        center.removeDeliveredNotifications(withIdentifiers: knownIDs)

        cleanupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pending = await center.pendingNotificationIdentifiers()
            let delivered = await center.deliveredNotificationIdentifiers()
            guard token == generation else { return }
            removeRestNotifications(
                pending: pending, delivered: delivered)
        }
    }

    func waitForSchedulingForTests() async {
        await scheduleTask?.value
        await cleanupTask?.value
    }

    private func removeRestNotifications(
        pending: [String], delivered: [String]
    ) {
        // Use the union for both removals. A request can move from pending to
        // delivered between the two async snapshots or during cancellation;
        // deleting each discovered id from both collections closes that race.
        let identifiers = Array(Set(
            (pending + delivered).filter(Self.isRestNotification)))
        center.removePendingNotificationRequests(
            withIdentifiers: identifiers)
        center.removeDeliveredNotifications(
            withIdentifiers: identifiers)
    }

    private static func isRestNotification(_ identifier: String) -> Bool {
        identifier == legacyNotificationID
            || identifier.hasPrefix(notificationPrefix)
    }
}

/// Audio + haptic "your rest is up" cue for the gym (#4). The rest countdown
/// was visual-only — fine when you're staring at the phone, useless when it's
/// in your pocket and your headphones are in. This plays a short chime, a
/// spoken "Rest's up — up next, <exercise>", and a success haptic the moment
/// rest elapses.
///
/// Two delivery paths, because the in-process poll Task that calls `play()` is
/// **suspended** once the phone locks or the app backgrounds (there is no
/// background-audio mode, by design — keeping a silent AVAudioSession alive to
/// dodge suspension is a battery-draining App-Review hazard):
///   - **Foreground** — `play()`: the rich chime + spoken cue + haptic.
///   - **Backgrounded / locked** — a scheduled *local notification*
///     (`scheduleNotification`). `UNTimeIntervalNotificationTrigger` is the
///     OS-sanctioned "alert me at a future instant regardless of app state":
///     it fires through suspension and termination, needs no Info.plist
///     background mode, only a runtime permission. The pending request is
///     cancelled when the foreground cue fires, on skip, and rescheduled on
///     +/−15, so the user hears the cue exactly once.
///
/// Design choices for the foreground cue:
///   - `.playback` category: the cue sounds through wired/Bluetooth headphones
///     AND ignores the mute switch (a gym cue you can't hear is pointless).
///     `.duckOthers` dips music briefly instead of stopping it; `.mixWithOthers`
///     lets a podcast keep playing underneath.
///   - The session is deactivated (with `.notifyOthersOnDeactivation`) after
///     the utterance finishes, so other audio un-ducks back to full volume.
///   - Gated by an @AppStorage toggle (default on) so it can be silenced
///     without code — see `restAudioCuesEnabled`.
@MainActor
enum RestCue {
    /// User preference key shared with any settings toggle. Default ON.
    static let defaultsKey = "restAudioCuesEnabled"

    private static let notificationCoordinator = RestNotificationCoordinator(
        center: SystemRestNotificationCenter())

    /// Honors the @AppStorage toggle (absent key → default ON).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Retained synthesizer — a local one would be deallocated mid-utterance
    /// and cut the speech off.
    private static let synth = AVSpeechSynthesizer()

    /// Request notification permission at the user's explicit workout-start
    /// action, before the runner begins. Rest scheduling deliberately never
    /// presents system UI: the first logged set must advance immediately.
    static func requestNotificationPermissionIfNeeded() async {
        guard enabled else { return }
        await notificationCoordinator.requestPermissionIfNeeded()
    }

    /// Schedule the backgrounded backstop only when permission already exists.
    /// If permission is denied (or has not been requested), the foreground
    /// `play()` path still covers an app-open workout without interrupting it.
    static func scheduleNotification(at end: Date) {
        guard enabled else { return }
        notificationCoordinator.schedule(at: end)
    }

    /// Whether the OS has already *delivered* our rest-cue notification — i.e.
    /// the background path fired while the app was suspended/locked. The
    /// foreground poll uses this to stay exactly-once: if the user was already
    /// alerted by the notification, it must not replay the in-app chime on
    /// resume. This is authoritative rather than timing-based — with no
    /// foreground-presentation delegate, iOS suppresses this notification while
    /// the app is active, so a delivered one means we were genuinely
    /// backgrounded across the deadline.
    static func notificationWasDelivered() async -> Bool {
        await notificationCoordinator.notificationWasDelivered()
    }

    /// Cancel any pending/delivered rest-cue notification — on skip, and right
    /// after the foreground cue fires so a foregrounded user isn't double-cued.
    static func cancelNotification() {
        notificationCoordinator.cancel()
    }

    static func play(upNext: String) {
        guard enabled else { return }

        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback,
                                 options: [.duckOthers, .mixWithOthers])
        try? session.setActive(true)

        // Short, distinctive system chime to grab attention before the speech.
        AudioServicesPlaySystemSound(1057)
        UINotificationFeedbackGenerator().notificationOccurred(.success)

        let phrase = upNext.isEmpty || upNext.uppercased() == "DONE"
            ? "Rest's up. Workout complete."
            : "Rest's up. Up next, \(upNext)."
        let utterance = AVSpeechUtterance(string: phrase)
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        utterance.postUtteranceDelay = 0.1
        synth.speak(utterance)

        // Un-duck other audio shortly after the utterance would have finished.
        // (AVSpeechSynthesizerDelegate would be tidier, but this avoids holding
        // a delegate object for a fire-and-forget cue.)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
