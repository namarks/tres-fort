import Foundation

/// Deadline-based cue selection: late wakeups skip missed beats instead of
/// playing a burst. Completion delivery uses app lifecycle and notification
/// evidence, since a slow foreground task still needs to sound the final tone.
struct TimedSetCountdown {
    enum Cue: Equatable {
        case tick(Int)
        case complete
    }

    let end: Date
    private var lastSecond = 6

    init(end: Date) { self.end = end }

    mutating func cue(at date: Date) -> Cue? {
        let remaining = end.timeIntervalSince(date)
        guard remaining <= 5 else { return nil }
        let second = max(0, Int(ceil(remaining)))
        guard second < lastSecond else { return nil }
        lastSecond = second
        return second == 0 ? .complete : .tick(second)
    }

    func nextWake(after date: Date) -> Date {
        let remaining = end.timeIntervalSince(date)
        let nextSecond = min(5, max(0, ceil(remaining) - 1))
        return end.addingTimeInterval(-nextSecond)
    }
}
