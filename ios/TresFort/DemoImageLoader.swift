import SwiftUI
import UIKit

/// Loads a 2-frame exercise demo for the demo sheet.
///
/// Resolution order per frame:
///   1. Bundled asset catalog (`UIImage(named: "{slug}__{frame}")`) —
///      foundational lifts shipped offline, zero latency.
///   2. Remote: `GET /api/exercises/:id/demo/:frame` (JWT-gated, R2-backed).
///      Cached by URLSession's default URLCache; the Worker route's
///      Cache-Control: immutable lets the cache key survive across launches.
///
/// Nil result on a frame → the demo sheet renders a cue card (name + muscle
/// map) instead. Network failures degrade to the same path.
@MainActor
final class DemoImageLoader: ObservableObject {
    @Published var frames: [UIImage?] = [nil, nil]
    @Published var isLoading = false

    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        // 64 MB on-disk / 16 MB memory — fits a few hundred ~50 KB webp
        // frames comfortably and survives backgrounded re-launches.
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                diskCapacity: 64 * 1024 * 1024,
                                directory: nil)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    func load(exerciseID: String, demoSlug: String?, jwt: String?) async {
        isLoading = true
        defer { isLoading = false }
        guard let slug = demoSlug, slug.isEmpty == false else {
            frames = [nil, nil]
            return
        }
        var out: [UIImage?] = [nil, nil]
        for frame in 0...1 {
            if let img = UIImage(named: "\(slug)__\(frame)") {
                out[frame] = img
                continue
            }
            if let jwt {
                out[frame] = await fetchRemote(exerciseID: exerciseID,
                                               frame: frame, jwt: jwt)
            }
        }
        frames = out
    }

    private func fetchRemote(exerciseID: String, frame: Int,
                             jwt: String) async -> UIImage? {
        let urlStr = APIClient().baseURL.absoluteString
            + "/api/exercises/\(exerciseID)/demo/\(frame)"
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200
            else { return nil }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
