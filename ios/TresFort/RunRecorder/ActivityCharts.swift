import Charts
import Foundation
import SwiftUI

/// An activity's chart series as `GET /api/activities/:id/streams` serves
/// them (src/activityStreams.ts, docs/plans/run-detail-charts P0). Every
/// array lines up with `t`, seconds of moving time; a series the activity
/// has no data for is nil, and a missing point inside one is nil.
struct ActivityStreams: Decodable, Equatable {
    let v: Int
    let t: [Double]
    let distance_m: [Double?]?
    let speed_mps: [Double?]?
    let heart_rate: [Double?]?
    let elevation_m: [Double?]?
    let moving_s: Double
    let total_distance_m: Double?
    let elevation_gain_m: Double?
}

struct ActivityStreamsResponse: Decodable, Equatable {
    let activity_id: String
    let source: String?
    let streams: ActivityStreams
}

extension APIClient {
    /// `GET /api/activities/:id/streams`. Nil when the activity has nothing
    /// to chart. intervals.icu being unavailable is an error, so it is asked
    /// for again later.
    func activityStreams(activityID: String, jwt: String) async throws -> ActivityStreamsResponse? {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
        let id = activityID.addingPercentEncoding(withAllowedCharacters: allowed) ?? activityID
        do {
            let response: ActivityStreamsResponse = try await get("api/activities/\(id)/streams", jwt: jwt)
            return response
        } catch let error as APIError where error.httpStatus == 404 {
            return nil
        }
    }
}

/// In-memory chart series for this process, per account, like
/// `ActivityRouteStore`: a finished activity's series don't change, so each
/// is read once, and "nothing to chart" is remembered for a few minutes.
@MainActor
final class ActivityStreamsStore {
    static let shared = ActivityStreamsStore()

    typealias Fetch = (_ activityID: String, _ jwt: String) async throws -> ActivityStreamsResponse?

    private let fetch: Fetch
    private let now: () -> Date
    private var accountID: String?
    private var loaded: [String: ActivityStreamsResponse] = [:]
    private var missing: [String: Date] = [:]
    static let missingLifetime: TimeInterval = 10 * 60

    init(fetch: @escaping Fetch = { id, jwt in try await APIClient().activityStreams(activityID: id, jwt: jwt) },
         now: @escaping () -> Date = Date.init) {
        self.fetch = fetch
        self.now = now
    }

    /// The series of `activityID`, or nil when it has none or the read
    /// failed. A failed read is tried again next time.
    func streams(for activityID: String, access: ActivityRouteAccess) async -> ActivityStreamsResponse? {
        if accountID != access.accountID {
            accountID = access.accountID
            loaded = [:]
            missing = [:]
        }
        if let streams = loaded[activityID] { return streams }
        if let since = missing[activityID], now().timeIntervalSince(since) < Self.missingLifetime { return nil }
        let streams: ActivityStreamsResponse?
        do {
            streams = try await fetch(activityID, access.jwt)
        } catch {
            return nil
        }
        guard accountID == access.accountID else { return nil }
        if let streams {
            loaded[activityID] = streams
            missing[activityID] = nil
        } else {
            missing[activityID] = now()
        }
        return streams
    }
}

extension ExternalActivity {
    /// Activities the server can chart: anything intervals.icu has (its
    /// streams carry heart rate for any sport) and every run with a route.
    var mayHaveStreams: Bool {
        source == "intervals" || mayHaveRoute
    }
}

/// The charts of one activity, in the member's units: pace (speed for a
/// ride), heart rate and elevation, over distance when it is known, else
/// over moving time. Pure, so it is unit tested.
struct ActivityChartSeries: Equatable {
    struct Point: Equatable, Identifiable {
        let id: Int
        /// Distance in the member's unit, or minutes.
        let x: Double
        let y: Double
        /// Points of one segment join; a gap starts a new one.
        let segment: Int
    }

    enum Axis: Equatable {
        case distance(RunDistanceUnit)
        case minutes
    }

    let axis: Axis
    /// Every point's position on the axis, one per sample of the activity,
    /// whether or not a series has a value there. A point's `id` indexes it.
    let xs: [Double]
    /// The whole activity's span on the axis, shared by every chart so the
    /// same position is the same point in all of them, even where one
    /// series starts late or ends early.
    let xDomain: ClosedRange<Double>
    /// Seconds per mile or kilometer; for a ride, mph or km/h.
    let pace: [Point]
    let paceIsSpeed: Bool
    /// The whole activity's pace or speed, from moving time and distance;
    /// averaging the points would weigh slow stretches too heavily.
    let paceAverage: Double?
    let heartRate: [Point]
    /// Feet with miles, meters with kilometers.
    let elevation: [Point]
    /// Feet or meters climbed.
    let climb: Int?
    let unit: RunDistanceUnit

    static let feetPerMeter = 3.280_84
    /// Slower than this is standing still, not a pace to draw.
    static let slowestMovingMps = 0.8

    init?(streams s: ActivityStreams, kind: String, unit: RunDistanceUnit) {
        guard s.v == 1, !s.t.isEmpty else { return nil }
        self.unit = unit
        let n = s.t.count
        func at<T>(_ array: [T?]?, _ i: Int) -> T? {
            guard let array, i < array.count else { return nil }
            return array[i]
        }
        let distances = (0..<n).map { at(s.distance_m, $0) }
        let byDistance = (s.total_distance_m ?? 0) > 0 && distances.allSatisfy { $0 != nil }
        axis = byDistance ? .distance(unit) : .minutes
        let xs: [Double] = (0..<n).map { i in
            byDistance ? (distances[i]! / unit.meters) : s.t[i] / 60
        }
        self.xs = xs
        let lo = xs.min() ?? 0
        let hi = xs.max() ?? 0
        xDomain = lo...(hi > lo ? hi : lo + 1)

        paceIsSpeed = kind == "ride"
        let paceValues: [Double?] = (0..<n).map { i in
            guard let mps = at(s.speed_mps, i) else { return nil }
            if kind == "ride" { return mps > 0 ? mps * 3600 / unit.meters : nil }
            guard mps >= Self.slowestMovingMps else { return nil }
            return unit.meters / mps
        }
        pace = Self.points(xs, Self.clampedToPercentiles(paceValues))
        if let meters = s.total_distance_m, meters > 0, s.moving_s > 0 {
            paceAverage = kind == "ride"
                ? (meters / unit.meters) / (s.moving_s / 3600)
                : s.moving_s / (meters / unit.meters)
        } else {
            paceAverage = nil
        }
        heartRate = Self.points(xs, (0..<n).map { at(s.heart_rate, $0) })
        let toUnit = unit == .miles ? Self.feetPerMeter : 1
        elevation = Self.points(xs, (0..<n).map { at(s.elevation_m, $0).map { $0 * toUnit } })
        climb = s.elevation_gain_m.map { Int(($0 * toUnit).rounded()) }
        if pace.isEmpty && heartRate.isEmpty && elevation.isEmpty { return nil }
    }

    /// Points with a value; a missing value ends the segment.
    static func points(_ xs: [Double], _ ys: [Double?]) -> [Point] {
        var out: [Point] = []
        var segment = 0
        var lastWasGap = false
        for (i, y) in ys.enumerated() {
            guard let y, y.isFinite else {
                if !out.isEmpty { lastWasGap = true }
                continue
            }
            if lastWasGap {
                segment += 1
                lastWasGap = false
            }
            out.append(Point(id: i, x: xs[i], y: y, segment: segment))
        }
        return out
    }

    /// Values held between the 2nd and 98th percentile, so one GPS hiccup
    /// doesn't squash the rest of the chart.
    static func clampedToPercentiles(_ values: [Double?]) -> [Double?] {
        let known = values.compactMap { $0 }.sorted()
        guard known.count >= 10 else { return values }
        let lo = known[Int(Double(known.count - 1) * 0.02)]
        let hi = known[Int(Double(known.count - 1) * 0.98)]
        return values.map { $0.map { min(max($0, lo), hi) } }
    }

    /// The sample nearest `x` on the shared axis, for the scrub read-out.
    /// Every chart reads this one sample, so none borrows a value from
    /// another part of the activity where its own series has a gap.
    static func nearestIndex(_ xs: [Double], to x: Double) -> Int? {
        xs.indices.min { abs(xs[$0] - x) < abs(xs[$1] - x) }
    }

    /// A series' value at sample `index`, or nil where it has none.
    static func point(_ points: [Point], at index: Int) -> Point? {
        points.first { $0.id == index }
    }

    var xUnitLabel: String {
        switch axis {
        case let .distance(unit): return unit.abbreviation
        case .minutes: return "min"
        }
    }

    var elevationUnit: String { unit == .miles ? "ft" : "m" }

    func paceText(_ value: Double) -> String {
        paceIsSpeed
            ? String(format: "%.1f %@", value, unit == .miles ? "mph" : "km/h")
            : "\(RunFormat.pace(value)) /\(unit.abbreviation)"
    }

    func xText(_ x: Double) -> String {
        switch axis {
        case let .distance(unit): return String(format: "%.2f %@", x, unit.abbreviation)
        case .minutes: return RunFormat.duration(x * 60)
        }
    }
}

/// Reads an activity's chart series when its card appears and draws them;
/// nothing until they arrive, and nothing for an activity with none.
struct ActivityChartsSection: View {
    let activity: ExternalActivity
    let access: ActivityRouteAccess?
    @AppStorage(RunDistanceUnit.preferenceKey) private var unitRaw = RunDistanceUnit.miles.rawValue
    @State private var loaded: Loaded?

    private struct Loaded {
        let activityID: String
        let streams: ActivityStreams
    }

    private var unit: RunDistanceUnit { RunDistanceUnit(rawValue: unitRaw) ?? .miles }

    var body: some View {
        Group {
            if let loaded, loaded.activityID == activity.id,
               let series = ActivityChartSeries(streams: loaded.streams, kind: activity.kind, unit: unit) {
                ActivityChartsView(series: series)
            }
        }
        .task(id: activity.id) {
            guard activity.mayHaveStreams, let access else { return }
            let response = await ActivityStreamsStore.shared.streams(for: activity.id, access: access)
            guard !Task.isCancelled else { return }
            loaded = response.map { Loaded(activityID: activity.id, streams: $0.streams) }
        }
    }
}

/// Pace, heart rate and elevation charts on one axis. Touching any chart
/// reads all three at that point.
struct ActivityChartsView: View {
    let series: ActivityChartSeries
    @State private var selectedX: Double?

    private var selectedIndex: Int? {
        selectedX.flatMap { ActivityChartSeries.nearestIndex(series.xs, to: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !series.pace.isEmpty {
                chart(title: series.paceIsSpeed ? "Speed" : "Pace", points: series.pace,
                      color: Theme.accent, reversed: !series.paceIsSpeed, average: series.paceAverage,
                      value: series.paceText, axisLabel: { v in
                          series.paceIsSpeed ? String(format: "%.0f", v) : RunFormat.pace(v)
                      })
                    .accessibilityIdentifier("activity.chart.pace")
            }
            if !series.heartRate.isEmpty {
                chart(title: "Heart rate", points: series.heartRate, color: Theme.danger, reversed: false,
                      value: { "\(Int($0.rounded())) bpm" }, axisLabel: { "\(Int($0.rounded()))" })
                    .accessibilityIdentifier("activity.chart.heartRate")
            }
            if !series.elevation.isEmpty {
                chart(title: series.climb.map { "Elevation · \($0) \(series.elevationUnit) climb" } ?? "Elevation",
                      points: series.elevation, color: Theme.done, reversed: false,
                      value: { "\(Int($0.rounded())) \(series.elevationUnit)" },
                      axisLabel: { "\(Int($0.rounded()))" })
                    .accessibilityIdentifier("activity.chart.elevation")
            }
            Text(selectedIndex.map { "At \(series.xText(series.xs[$0]))" } ?? "Touch a chart to read a point.")
                .font(.caption)
                .foregroundStyle(Theme.dim)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("activity.charts")
    }

    private func chart(title: String,
                       points: [ActivityChartSeries.Point],
                       color: Color,
                       reversed: Bool,
                       average overall: Double? = nil,
                       value: @escaping (Double) -> String,
                       axisLabel: @escaping (Double) -> String) -> some View {
        let index = selectedIndex
        let reading = index.flatMap { ActivityChartSeries.point(points, at: $0) }
        let average = overall ?? points.map(\.y).reduce(0, +) / Double(max(1, points.count))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title.uppercased())
                    .font(Theme.mono(9, .bold)).tracking(1)
                    .foregroundStyle(Theme.dim)
                Spacer()
                Text(index == nil ? "avg \(value(average))" : reading.map { value($0.y) } ?? "–")
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.text)
            }
            Chart {
                ForEach(points) { p in
                    LineMark(x: .value(series.xUnitLabel, p.x),
                             y: .value(title, p.y),
                             series: .value("Segment", p.segment))
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                }
                if let index {
                    RuleMark(x: .value(series.xUnitLabel, series.xs[index]))
                        .foregroundStyle(Theme.muted)
                }
                if let reading {
                    PointMark(x: .value(series.xUnitLabel, reading.x), y: .value(title, reading.y))
                        .foregroundStyle(color)
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: series.xDomain)
            .chartXSelection(value: $selectedX)
            .chartYScale(domain: .automatic(includesZero: false, reversed: reversed))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.3))
                    AxisValueLabel {
                        Text(v.as(Double.self).map { x in
                            series.axis == .minutes ? "\(Int(x))" : String(format: "%g", x)
                        } ?? "")
                    }
                    .foregroundStyle(Theme.muted)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { v in
                    AxisGridLine().foregroundStyle(Theme.dim.opacity(0.3))
                    AxisValueLabel {
                        Text(v.as(Double.self).map(axisLabel) ?? "")
                    }
                    .foregroundStyle(Theme.muted)
                }
            }
            .frame(height: 110)
        }
    }
}
