import AVFoundation
import AudioToolbox
import UIKit
import UserNotifications

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
enum RestCue {
    /// User preference key shared with any settings toggle. Default ON.
    static let defaultsKey = "restAudioCuesEnabled"

    /// Single in-flight rest cue — scheduling a new one replaces the old.
    private static let notificationID = "rest-cue"

    /// Honors the @AppStorage toggle (absent key → default ON).
    static var enabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            || UserDefaults.standard.bool(forKey: defaultsKey)
    }

    /// Retained synthesizer — a local one would be deallocated mid-utterance
    /// and cut the speech off.
    private static let synth = AVSpeechSynthesizer()

    /// Schedule the backgrounded backstop: a local notification that fires when
    /// rest elapses even if the app is suspended. Lazily requests permission
    /// (a no-op after the first decision); silently does nothing if denied —
    /// the foreground `play()` path still covers the app-open case.
    static func scheduleNotification(at end: Date) {
        guard enabled else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Rest's up"
            // Deliberately generic: the next lift isn't reliably known when the
            // rest is scheduled (the runner's slot index advances only after the
            // set is logged), so naming it here risks the wrong exercise. The
            // rich foreground cue speaks the correct "up next" name, and the
            // runner already shows it on screen.
            content.body = "Time for your next set."
            content.sound = .default
            // A gym rest timer genuinely is time-sensitive; degrades to a
            // normal alert if the Time Sensitive entitlement isn't present.
            content.interruptionLevel = .timeSensitive
            // Never schedule in the past; min 1s so the trigger is valid.
            let trigger = UNTimeIntervalNotificationTrigger(
                timeInterval: max(end.timeIntervalSinceNow, 1), repeats: false)
            let req = UNNotificationRequest(
                identifier: notificationID, content: content, trigger: trigger)
            center.removePendingNotificationRequests(withIdentifiers: [notificationID])
            center.add(req)
        }
    }

    /// Cancel any pending/delivered rest-cue notification — on skip, and right
    /// after the foreground cue fires so a foregrounded user isn't double-cued.
    static func cancelNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [notificationID])
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
