import CoreLocation
import Foundation
import HealthKit

/// The GPS route Apple Health saved with a run another app recorded, such as
/// Strava (docs/plans/run-recorder P6(b)). The app reads it and sends it to
/// `PUT /api/activities/healthkit/:id/route`, so the run shows its map in the
/// app and on the web like a run recorded in Tres Fort. Runs the recorder
/// saved keep their route through the recording itself and are skipped.
enum HealthWorkoutRoute {
    /// A gap between two fixes longer than this starts a new line, as a pause
    /// does in a run recorded in the app (the server's SAMPLE_GAP_MS).
    static let gap: TimeInterval = 60

    /// Whether the Tres Fort recorder saved this workout.
    static func isFromRecorder(_ workout: HKWorkout) -> Bool {
        isRecorderTag(workout.metadata?[HKMetadataKeyExternalUUID] as? String)
    }

    static func isRecorderTag(_ externalID: String?) -> Bool {
        externalID?.hasPrefix(RunRecordingHealthTag.prefix) == true
    }

    /// The route in the encoding the server keeps (src/activityRoute.ts):
    /// each of Health's route objects, and each stretch between gaps longer
    /// than `gap`, is its own line. Fixes Health marks invalid (negative
    /// accuracy) and fixes that go back in time are left out; an altitude
    /// with negative vertical accuracy is unknown. Nil when no fix is left.
    static func encode(_ routes: [[CLLocation]]) -> EncodedActivityRoute? {
        var segments: [[CLLocation]] = []
        var last: Date?
        for route in routes {
            var current: [CLLocation] = []
            for fix in route.sorted(by: { $0.timestamp < $1.timestamp }) {
                guard fix.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(fix.coordinate),
                      !(fix.coordinate.latitude == 0 && fix.coordinate.longitude == 0) else { continue }
                if let last, fix.timestamp < last { continue }
                if let previous = current.last, fix.timestamp.timeIntervalSince(previous.timestamp) > gap {
                    segments.append(current)
                    current = []
                }
                current.append(fix)
                last = fix.timestamp
            }
            if !current.isEmpty { segments.append(current) }
        }
        guard let first = segments.first?.first else { return nil }
        let ms = { (date: Date) in Int((date.timeIntervalSince1970 * 1000).rounded()) }
        let micro = { (degrees: Double) in Int((degrees * 1_000_000).rounded()) }
        var dt: [Int] = []
        var dlat: [Int] = []
        var dlon: [Int] = []
        var alt: [Int?] = []
        var breaks: [Int] = []
        var t = ms(first.timestamp)
        var lat = 0
        var lon = 0
        for segment in segments {
            if !dt.isEmpty { breaks.append(dt.count) }
            for fix in segment {
                let pt = ms(fix.timestamp)
                let plat = micro(fix.coordinate.latitude)
                let plon = micro(fix.coordinate.longitude)
                dt.append(pt - t)
                dlat.append(plat - lat)
                dlon.append(plon - lon)
                alt.append(fix.verticalAccuracy >= 0 && abs(fix.altitude) < 100_000
                           ? Int((fix.altitude * 10).rounded()) : nil)
                t = pt
                lat = plat
                lon = plon
            }
        }
        return EncodedActivityRoute(v: 1, start_ms: ms(first.timestamp), dt: dt, dlat: dlat, dlon: dlon,
                                    alt: alt, breaks: breaks)
    }

    /// Every location of the workout's routes, one list per route object in
    /// time order. Nil when HealthKit fails (for example while the phone is
    /// locked), so a later sync tries again; a denied read is
    /// indistinguishable from no route and returns an empty list.
    static func read(for workout: HKWorkout, store: HKHealthStore) async -> [[CLLocation]]? {
        guard let routes = await routeObjects(of: workout, store: store) else { return nil }
        var out: [[CLLocation]] = []
        for route in routes.sorted(by: { $0.startDate < $1.startDate }) {
            guard let locations = await locations(of: route, store: store) else { return nil }
            out.append(locations)
        }
        return out
    }

    private static func routeObjects(of workout: HKWorkout, store: HKHealthStore) async -> [HKWorkoutRoute]? {
        await withCheckedContinuation { continuation in
            let query = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(),
                                      predicate: HKQuery.predicateForObjects(from: workout),
                                      limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, error in
                continuation.resume(returning: error == nil ? (samples ?? []).compactMap { $0 as? HKWorkoutRoute } : nil)
            }
            store.execute(query)
        }
    }

    private static func locations(of route: HKWorkoutRoute, store: HKHealthStore) async -> [CLLocation]? {
        let box = RouteLocationAccumulator()
        return await withCheckedContinuation { continuation in
            let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                guard !box.finished else { return }
                if error != nil {
                    box.finished = true
                    continuation.resume(returning: nil)
                    return
                }
                box.locations.append(contentsOf: locations ?? [])
                if done {
                    box.finished = true
                    continuation.resume(returning: box.locations)
                }
            }
            store.execute(query)
        }
    }
}

/// Collects a route query's batches, which HealthKit delivers one after
/// another on its own queue.
private final class RouteLocationAccumulator: @unchecked Sendable {
    var locations: [CLLocation] = []
    var finished = false
}

extension EncodedActivityRoute {
    /// The `route` body of `PUT /api/activities/healthkit/:id/route`.
    var jsonBody: [String: Any] {
        ["v": v, "start_ms": start_ms, "dt": dt, "dlat": dlat, "dlon": dlon,
         "alt": alt.map { $0.map { $0 as Any } ?? NSNull() }, "breaks": breaks]
    }
}

/// The Apple Health runs whose route the app has dealt with, per account:
/// sent, or found to have none. Each entry keeps the run's start, so entries
/// older than the look-back are dropped.
struct HealthRouteLedger: Equatable {
    private(set) var entries: [String: Double]

    init(stored: Any?) {
        entries = (stored as? [String: Double]) ?? [:]
    }

    /// What is saved in the account's preferences.
    var stored: [String: Double] { entries }

    func contains(_ workoutID: UUID) -> Bool {
        entries[workoutID.uuidString] != nil
    }

    mutating func record(_ workoutID: UUID, start: Date) {
        entries[workoutID.uuidString] = start.timeIntervalSince1970
    }

    mutating func prune(before cutoff: Date) {
        entries = entries.filter { $0.value >= cutoff.timeIntervalSince1970 }
    }
}

extension APIClient {
    /// `PUT /api/activities/healthkit/:id/route` — the route Apple Health saved
    /// with a run another app recorded. 404 until the run itself is stored.
    @discardableResult
    func putHealthKitRoute(workoutID: UUID, route: EncodedActivityRoute,
                           jwt: String) async throws -> HealthRouteSaved {
        try await put("api/activities/healthkit/\(workoutID.uuidString)/route",
                      body: ["route": route.jsonBody], jwt: jwt)
    }

    struct HealthRouteSaved: Decodable, Equatable {
        let activity_id: String
        let point_count: Int
    }
}
