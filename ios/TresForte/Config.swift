import Foundation

enum Config {
    /// Live Cloudflare Worker (source of truth). Server, not the device,
    /// owns the data; the app is a cache + executor.
    static let apiBaseURL = URL(string: "https://tres-forte.nmarkspdx.workers.dev")!
}
