import AVFoundation
import XCTest
@testable import TresFort

final class TimedSetCountdownTests: XCTestCase {
    private let end = Date(timeIntervalSince1970: 2_000_000_000)

    func testFiveBeatsThenOneCompletionAtDeadline() {
        var countdown = TimedSetCountdown(end: end)
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(-5.01)))
        for second in stride(from: 5, through: 1, by: -1) {
            let date = end.addingTimeInterval(-Double(second))
            XCTAssertEqual(countdown.cue(at: date), .tick(second))
            XCTAssertNil(countdown.cue(at: date.addingTimeInterval(0.1)))
        }
        XCTAssertEqual(countdown.cue(at: end), .complete)
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(0.1)))
    }

    func testShortHoldStartsAtItsActualRemainingTime() {
        var countdown = TimedSetCountdown(end: end)
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(-3)), .tick(3))
        XCTAssertEqual(countdown.nextWake(after: end.addingTimeInterval(-3)),
                       end.addingTimeInterval(-2))
    }

    func testLateWakeSkipsMissedBeatsWithoutShiftingDeadline() {
        var countdown = TimedSetCountdown(end: end)
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(-4.8)), .tick(5))
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(-1.9)), .tick(2))
        XCTAssertEqual(countdown.nextWake(after: end.addingTimeInterval(-1.9)),
                       end.addingTimeInterval(-1))
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(0.05)), .complete)
    }

    func testOverdueResumeNeverReplaysAnAlarm() {
        var countdown = TimedSetCountdown(end: end)
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(10)))
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(11)))
    }

    func testEarlyWakeWaitsForTheOriginalBoundary() {
        let countdown = TimedSetCountdown(end: end)
        XCTAssertEqual(countdown.nextWake(after: end.addingTimeInterval(-60)),
                       end.addingTimeInterval(-5))
        XCTAssertEqual(countdown.nextWake(after: end.addingTimeInterval(-4.001)),
                       end.addingTimeInterval(-4))
        XCTAssertEqual(countdown.nextWake(after: end.addingTimeInterval(-0.001)), end)
    }

    func testClockMovingBackDoesNotReplayAlreadyHeardBeat() {
        var countdown = TimedSetCountdown(end: end)
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(-3)), .tick(3))
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(-4)))
        XCTAssertNil(countdown.cue(at: end.addingTimeInterval(-3)))
        XCTAssertEqual(countdown.cue(at: end.addingTimeInterval(-2)), .tick(2))
    }

    func testBundledTonesArePlayableAndCompletionIsDistinct() throws {
        // Bundle lookup catches missing XcodeGen resource membership too.
        let appBundle = Bundle(for: SyncModel.self)
        let tickURL = try XCTUnwrap(appBundle.url(forResource: "timed-set-tick", withExtension: "wav"))
        let finalURL = try XCTUnwrap(appBundle.url(forResource: "timed-set-complete", withExtension: "wav"))
        let tick = try AVAudioPlayer(contentsOf: tickURL)
        let final = try AVAudioPlayer(contentsOf: finalURL)
        XCTAssertEqual(tick.duration, 0.12, accuracy: 0.001)
        XCTAssertEqual(final.duration, 0.55, accuracy: 0.001)
        XCTAssertNotEqual(try Data(contentsOf: tickURL), try Data(contentsOf: finalURL))
    }
}
