import AVFoundation
import AudioToolbox
import UIKit

/// Audio + haptic "your rest is up" cue for the gym (#4). The rest countdown
/// was visual-only — fine when you're staring at the phone, useless when it's
/// in your pocket and your headphones are in. This plays a short chime, a
/// spoken "Rest's up — up next, <exercise>", and a success haptic the moment
/// rest elapses.
///
/// Design choices:
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

    /// Retained synthesizer — a local one would be deallocated mid-utterance
    /// and cut the speech off.
    private static let synth = AVSpeechSynthesizer()

    static func play(upNext: String) {
        guard UserDefaults.standard.object(forKey: defaultsKey) == nil
            || UserDefaults.standard.bool(forKey: defaultsKey) else { return }

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
