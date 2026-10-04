import AVFoundation
import Combine
import UIKit

@MainActor
final class StationRecordingStill: ObservableObject {
    typealias Loader = @Sendable (URL, Double) async throws -> UIImage
    @Published private(set) var image: UIImage?
    @Published private(set) var error: String?
    private let access: StationAccess
    private let loader: Loader
    private var generation = UUID()
    private var task: Task<UIImage, Error>?

    init(access: StationAccess, loader: @escaping Loader = { url, seconds in
        try await StationRecordingStill.decode(url: url, seconds: seconds)
    }) {
        self.access = access
        self.loader = loader
        access.observeInvalidation { [weak self] in
            guard let self else { return false }
            self.clear()
            return true
        }
    }

    func load(recording: StationRecording, at seconds: Double, store: StationRecordingStore) async {
        clear()
        guard access.validate(), store.session === access.session else { return }
        let token = generation
        do {
            let url = try store.videoURL(for: recording.id)
            let loader = self.loader
            let session = access.session
            let loading = Task {
                try session.requireActive()
                return try await loader(url, seconds)
            }
            task = loading
            let image = try await withTaskCancellationHandler { try await loading.value }
                onCancel: { loading.cancel() }
            try Task.checkCancellation()
            guard access.validate(), generation == token else { return }
            self.image = image
            task = nil
        } catch is CancellationError { }
        catch {
            guard access.validate(), generation == token, !Task.isCancelled else { return }
            self.error = "Could not display this video frame."
            task = nil
        }
    }

    func clear() {
        generation = UUID()
        task?.cancel()
        task = nil
        image = nil
        error = nil
    }

    private nonisolated static func decode(url: URL, seconds: Double) async throws -> UIImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let result = try await withTaskCancellationHandler {
            try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600_000))
        } onCancel: { generator.cancelAllCGImageGeneration() }
        try Task.checkCancellation()
        return UIImage(cgImage: result.image)
    }

    deinit { task?.cancel() }
}
