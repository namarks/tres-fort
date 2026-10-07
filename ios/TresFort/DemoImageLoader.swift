import SwiftUI
import UIKit
import ImageIO

/// Loads a two-frame technique demo or one static preview thumbnail.
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
    enum Presentation { case demo, thumbnail }

    @Published var frames: [UIImage?] = [nil, nil]
    @Published var isLoading = false

    private static let sharedSession: URLSession = {
#if DEBUG && targetEnvironment(simulator)
        if UIFixtureScenario.selected != nil { return UIFixtureProtocol.session }
#endif
        let cfg = URLSessionConfiguration.default
        // 64 MB on-disk / 16 MB memory — fits a few hundred ~50 KB webp
        // frames comfortably and survives backgrounded re-launches.
        cfg.urlCache = URLCache(memoryCapacity: 16 * 1024 * 1024,
                                diskCapacity: 64 * 1024 * 1024,
                                directory: nil)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private let session: URLSession
    private let bundledImage: (String) -> UIImage?
    private var generation = 0

    init(session: URLSession? = nil,
         bundledImage: @escaping (String) -> UIImage? = { UIImage(named: $0) }) {
        self.session = session ?? Self.sharedSession
        self.bundledImage = bundledImage
    }

    func load(exerciseID: String, demoSlug: String?, jwt: String?,
              presentation: Presentation = .demo) async {
        generation += 1
        let requestGeneration = generation
        frames = [nil, nil]
        isLoading = true
        defer {
            if generation == requestGeneration { isLoading = false }
        }
        guard !Task.isCancelled, let slug = demoSlug, !slug.isEmpty else { return }
        var out = (0...1).map { bundledImage("\(slug)__\($0)") }
        // A preview needs only one still. Prefer either offline frame before
        // making a request, then stop after the first available remote still.
        if presentation == .thumbnail, let local = out.compactMap({ $0 }).first {
            frames = [local, nil]
            return
        }
        for frame in 0...1 {
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if out[frame] == nil, let jwt {
                out[frame] = await fetchRemote(exerciseID: exerciseID,
                    frame: frame, slug: slug, jwt: jwt, presentation: presentation)
            }
            guard !Task.isCancelled, generation == requestGeneration else { return }
            if presentation == .thumbnail, let image = out[frame] {
                frames = [image, nil]
                return
            }
        }
        frames = out
    }

    private func fetchRemote(exerciseID: String, frame: Int, slug: String,
                             jwt: String, presentation: Presentation) async -> UIImage? {
        let path = Config.apiBaseURL.appendingPathComponent("api/exercises")
            .appendingPathComponent(exerciseID).appendingPathComponent("demo/\(frame)")
        var components = URLComponents(url: path, resolvingAgainstBaseURL: false)
        // The route resolves a slug from the catalog. Include it in the cache
        // key so an updated catalog image cannot reuse a previous slug's bytes.
        components?.queryItems = [URLQueryItem(name: "demo", value: slug)]
        guard let url = components?.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, http.statusCode == 200
            else { return nil }
            if presentation == .thumbnail {
                guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 192
                      ] as CFDictionary) else { return nil }
                return UIImage(cgImage: image)
            }
            return UIImage(data: data)
        } catch {
            return nil
        }
    }
}
