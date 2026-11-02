import Foundation
import MapKit
import SwiftUI

/// A recorded run's GPS route as `GET /api/activities/:id/route` serves it
/// (src/activityRoute.ts, docs/plans/run-recorder P5). Times are delta-coded
/// milliseconds and coordinates delta-coded micro-degrees: point i is the sum
/// of entries 0...i. `breaks` lists the first index of each segment after the
/// first; the recorder starts a new segment after a pause.
struct EncodedActivityRoute: Decodable, Equatable {
    let v: Int
    let start_ms: Int
    let dt: [Int]
    let dlat: [Int]
    let dlon: [Int]
    let alt: [Int?]
    let breaks: [Int]

    /// Coordinates per segment, in order. Empty when the arrays disagree or
    /// the format is unknown.
    var segments: [[CLLocationCoordinate2D]] {
        guard v == 1, dlat.count == dt.count, dlon.count == dt.count else { return [] }
        let starts = Set(breaks)
        var out: [[CLLocationCoordinate2D]] = []
        var current: [CLLocationCoordinate2D] = []
        var lat = 0
        var lon = 0
        for i in dt.indices {
            if starts.contains(i), !current.isEmpty {
                out.append(current)
                current = []
            }
            lat += dlat[i]
            lon += dlon[i]
            let point = CLLocationCoordinate2D(latitude: Double(lat) / 1_000_000,
                                               longitude: Double(lon) / 1_000_000)
            if CLLocationCoordinate2DIsValid(point) { current.append(point) }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// Segments a map can draw as a line: at least two points.
    var drawableSegments: [[CLLocationCoordinate2D]] {
        segments.filter { $0.count > 1 }
    }
}

struct ActivityRouteResponse: Decodable, Equatable {
    /// The recording that carries the route, which can differ from the
    /// activity asked for when that is the intervals.icu copy of the run.
    let activity_id: String
    let recording_id: String
    let route: EncodedActivityRoute
}

extension APIClient {
    /// `GET /api/activities/:id/route`. Nil when the activity has no route.
    func activityRoute(activityID: String, jwt: String) async throws -> ActivityRouteResponse? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let id = activityID.addingPercentEncoding(withAllowedCharacters: allowed) ?? activityID
        do {
            let response: ActivityRouteResponse = try await get("api/activities/\(id)/route", jwt: jwt)
            return response
        } catch let error as APIError where error.httpStatus == 404 {
            return nil
        }
    }
}

/// The account and bearer a route read uses. Routes are private, so the
/// cache below never serves one account's routes to another.
struct ActivityRouteAccess: Equatable {
    let accountID: String
    let jwt: String
}

/// In-memory routes for this process, per account. A route never changes
/// once stored, so it is fetched once. "No route" is remembered for a few
/// minutes only, since the intervals.icu copy of a run can sync before the
/// run it duplicates is matched to it.
@MainActor
final class ActivityRouteStore {
    static let shared = ActivityRouteStore()

    typealias Fetch = (_ activityID: String, _ jwt: String) async throws -> ActivityRouteResponse?

    private let fetch: Fetch
    private let now: () -> Date
    private var accountID: String?
    private var routes: [String: ActivityRouteResponse] = [:]
    private var missing: [String: Date] = [:]
    static let missingLifetime: TimeInterval = 10 * 60

    init(fetch: @escaping Fetch = { id, jwt in try await APIClient().activityRoute(activityID: id, jwt: jwt) },
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    /// The route behind `activityID`, or nil when it has none or the read
    /// failed. A failed read is tried again next time.
    func route(for activityID: String, access: ActivityRouteAccess) async -> ActivityRouteResponse? {
        if accountID != access.accountID {
            accountID = access.accountID
            routes = [:]
            missing = [:]
        }
        if let route = routes[activityID] { return route }
        if let since = missing[activityID], now().timeIntervalSince(since) < Self.missingLifetime { return nil }
        let route: ActivityRouteResponse?
        do {
            route = try await fetch(activityID, access.jwt)
        } catch {
            return nil
        }
        // The account may have changed while the read was in flight.
        guard accountID == access.accountID else { return nil }
        if let route {
            routes[activityID] = route
            missing[activityID] = nil
        } else {
            missing[activityID] = now()
        }
        return route
    }
}

/// A route on a map: every segment as its own line, framed to fit.
struct ActivityRouteMap: View {
    let segments: [[CLLocationCoordinate2D]]
    var interactive = false

    var body: some View {
        Map(initialPosition: Self.camera(for: segments),
            interactionModes: interactive ? .all : []) {
            ForEach(segments.indices, id: \.self) { index in
                MapPolyline(coordinates: segments[index])
                    .stroke(Theme.accent, lineWidth: 4)
            }
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
    }

    static func camera(for segments: [[CLLocationCoordinate2D]]) -> MapCameraPosition {
        region(for: segments).map { .region($0) } ?? .automatic
    }

    /// The smallest region showing every point, with a margin, and never
    /// closer than about 300 m across.
    static func region(for segments: [[CLLocationCoordinate2D]]) -> MKCoordinateRegion? {
        let points = segments.flatMap { $0 }
        guard let first = points.first else { return nil }
        var minLat = first.latitude, maxLat = first.latitude
        var minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude)
            maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude)
            maxLon = max(maxLon, p.longitude)
        }
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.3, 0.003),
                                    longitudeDelta: max((maxLon - minLon) * 1.3, 0.003))
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// The route thumbnail on a run's card. Tapping it opens the route full
/// screen, where it can be moved and zoomed.
struct ActivityRouteThumbnail: View {
    let segments: [[CLLocationCoordinate2D]]
    @State private var showsFullMap = false

    var body: some View {
        Button {
            showsFullMap = true
        } label: {
            ActivityRouteMap(segments: segments)
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .allowsHitTesting(false)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Route map")
        .accessibilityHint("Opens the route full screen.")
        .accessibilityIdentifier("activity.routeMap")
        .sheet(isPresented: $showsFullMap) {
            NavigationStack {
                ActivityRouteMap(segments: segments, interactive: true)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Route")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showsFullMap = false }
                        }
                    }
            }
        }
    }
}

extension ExternalActivity {
    /// Only runs recorded in the app have a route, shown either as the
    /// recording itself or as the intervals.icu copy it was matched to.
    var mayHaveRecordedRoute: Bool {
        kind == "run" && (source == "recording" || source == "intervals")
    }
}

/// Reads a run's route when its card appears and hands the drawable
/// segments to `content`: none until the route arrives, and none for an
/// activity that can't have one.
struct WithActivityRoute<Content: View>: View {
    let activity: ExternalActivity?
    let access: ActivityRouteAccess?
    @ViewBuilder let content: (_ segments: [[CLLocationCoordinate2D]]) -> Content
    @State private var loaded: LoadedRoute?

    private struct LoadedRoute {
        let activityID: String
        let segments: [[CLLocationCoordinate2D]]
    }

    var body: some View {
        content(loaded?.activityID == activity?.id ? loaded?.segments ?? [] : [])
            .task(id: activity?.id) {
                guard let activity, activity.mayHaveRecordedRoute, let access else { return }
                let route = await ActivityRouteStore.shared.route(for: activity.id, access: access)
                guard !Task.isCancelled else { return }
                loaded = LoadedRoute(activityID: activity.id, segments: route?.route.drawableSegments ?? [])
            }
    }
}
