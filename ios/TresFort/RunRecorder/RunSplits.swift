import AVFoundation
import Foundation

/// A finished mile or kilometer, announced while the run records.
struct RunSplit: Equatable {
    var number: Int
    var unit: RunDistanceUnit
    /// Moving seconds for this split alone.
    var seconds: Double
    /// Moving seconds per unit over the whole run so far.
    var averagePace: Double

    /// "Mile 3. Split 8 32. Average pace 8 41 a mile."
    var spokenText: String {
        "\(unit.spokenName.capitalized) \(number). Split \(Self.spokenPace(seconds)). "
            + "Average pace \(Self.spokenPace(averagePace)) a \(unit.spokenName)."
    }

    /// A pace or split time the way a runner says it: "6 30", "6 oh 5", or
    /// "7 minutes" on the minute. Never "6:30", which the speech voice reads
    /// as a time of day ("six thirty" is fine, "seven o'clock" is not). An
    /// hour or more falls back to words.
    static func spokenPace(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        guard total >= 60, total < 3600 else { return spoken(seconds) }
        let minutes = total / 60, rest = total % 60
        switch rest {
        case 0: return "\(minutes) minute\(minutes == 1 ? "" : "s")"
        case 1..<10: return "\(minutes) oh \(rest)"
        default: return "\(minutes) \(rest)"
        }
    }

    static func spoken(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let parts = [(total / 3600, "hour"), ((total % 3600) / 60, "minute"), (total % 60, "second")]
            .filter { $0.0 > 0 }
            .map { "\($0.0) \($0.1)\($0.0 == 1 ? "" : "s")" }
        return parts.isEmpty ? "0 seconds" : parts.joined(separator: " ")
    }
}

/// Watches distance and moving time for the next whole mile or kilometer.
struct RunSplitTracker {
    let unit: RunDistanceUnit
    private(set) var completed: Int
    private var lastSplitSeconds: Double

    /// Starts past the splits already run, so a recovered run or a changed
    /// unit doesn't announce them again. Their time is estimated from the
    /// average so far.
    init(unit: RunDistanceUnit, meters: Double = 0, movingSeconds: Double = 0) {
        self.unit = unit
        completed = Int(max(0, meters) / unit.meters)
        lastSplitSeconds = meters > 0 ? movingSeconds * Double(completed) * unit.meters / meters : 0
    }

    /// The split just finished, if the distance reached a new whole unit. A
    /// jump across several reports only the latest, with the time shared out.
    mutating func update(meters: Double, movingSeconds: Double) -> RunSplit? {
        let reached = Int(max(0, meters) / unit.meters)
        guard reached > completed else { return nil }
        let seconds = (movingSeconds - lastSplitSeconds) / Double(reached - completed)
        completed = reached
        lastSplitSeconds = movingSeconds
        return RunSplit(number: reached, unit: unit, seconds: max(0, seconds),
                        averagePace: movingSeconds / (meters / unit.meters))
    }
}

@MainActor
protocol RunSplitSpeaking: AnyObject {
    func speak(_ text: String)
}

/// Speaks over music or a podcast, ducking it, then hands the audio back.
/// The run's workout session keeps the app running while the phone is
/// locked, and the beta's audio background mode lets it speak then.
@MainActor
final class SystemRunSplitSpeaker: NSObject, RunSplitSpeaking, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    func speak(_ text: String) {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .voicePrompt,
                                 options: [.duckOthers, .interruptSpokenAudioAndMixWithOthers])
        try? session.setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = TimerCueVoice.preferred()
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.release() }
    }

    private func release() {
        guard !synthesizer.isSpeaking else { return }
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}
