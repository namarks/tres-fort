import AppIntents
import Foundation

/// LiveActivityIntent runs in the app process. The recorder that owns the
/// run sets this handler while it records, so an activity left from an older
/// run, or another account, controls nothing.
@MainActor
enum RunRecorderControl {
    static var handler: ((String, String) async -> Bool)?
}

/// Pause, resume and finish from the run's Live Activity.
struct RunRecorderControlIntent: LiveActivityIntent {
    enum Action: String {
        case pause
        case resume
        case finish
    }

    static var title: LocalizedStringResource = "Control run recording"
    static var isDiscoverable = false
    @Parameter(title: "Run") var recordingID: String
    @Parameter(title: "Action") var action: String

    init() {}
    init(recordingID: String, action: Action) {
        self.recordingID = recordingID
        self.action = action.rawValue
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await RunRecorderControl.handler?(recordingID, action) == true else {
            throw RunUnavailable()
        }
        return .result()
    }

    private struct RunUnavailable: LocalizedError {
        var errorDescription: String? { "Open Tres Fort to check this run." }
    }
}
