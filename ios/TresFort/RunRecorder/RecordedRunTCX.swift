import Foundation

/// TCX (Garmin Training Center v2) for a recorded run, the file intervals.icu
/// analyzes like a watch upload. TCX rather than GPX because it carries the
/// workout builder's totals: the lap holds moving time and distance, and each
/// track point holds a cumulative distance scaled to that total, so the
/// uploaded run matches what the recorder showed. Each pause starts a new
/// track, and the distance covered while paused never counts.
enum RecordedRunTCX {
    /// A heart-rate sample further than this from a track point is not
    /// attached to it, so a gap in HR stays a gap instead of a stale value.
    static let heartRateMatchWindow: TimeInterval = 5

    static func encode(_ run: RecordedRun) -> Data {
        let tracks = segments(run)
        let gpsDistance = tracks.reduce(0.0) { $0 + segmentLength($1) }
        let totalDistance = run.distanceMeters > 0 ? run.distanceMeters : gpsDistance
        let scale = gpsDistance > 0 ? totalDistance / gpsDistance : 0

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>\(timestamp(run.startedAt))</Id>
              <Lap StartTime="\(timestamp(run.startedAt))">
                <TotalTimeSeconds>\(decimal(max(run.movingSeconds, 0)))</TotalTimeSeconds>
                <DistanceMeters>\(decimal(totalDistance))</DistanceMeters>
                <Calories>0</Calories>
                <Intensity>Active</Intensity>
                <TriggerMethod>Manual</TriggerMethod>

        """
        let heartRates = run.heartRates.sorted { $0.timestamp < $1.timestamp }
        var hrIndex = 0
        var distance = 0.0
        for track in tracks {
            xml += "        <Track>\n"
            for (i, point) in track.enumerated() {
                if i > 0 { distance += meters(track[i - 1], point) * scale }
                xml += "          <Trackpoint><Time>\(timestamp(point.timestamp))</Time>"
                xml += "<Position><LatitudeDegrees>\(coordinate(point.latitude))</LatitudeDegrees>"
                xml += "<LongitudeDegrees>\(coordinate(point.longitude))</LongitudeDegrees></Position>"
                if let altitude = point.altitude, altitude.isFinite {
                    xml += "<AltitudeMeters>\(decimal(altitude))</AltitudeMeters>"
                }
                xml += "<DistanceMeters>\(decimal(distance))</DistanceMeters>"
                if let bpm = nearestHeartRate(to: point.timestamp, in: heartRates, from: &hrIndex) {
                    xml += "<HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm>"
                }
                xml += "</Trackpoint>\n"
            }
            xml += "        </Track>\n"
        }
        xml += """
              </Lap>
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }

    /// Track points split into runs of moving time. A point recorded inside a
    /// pause is dropped, and a point after a pause starts a new segment.
    static func segments(_ run: RecordedRun) -> [[RecordedRun.RoutePoint]] {
        var result: [[RecordedRun.RoutePoint]] = []
        var segment: Int?
        for point in run.points.sorted(by: { $0.timestamp < $1.timestamp }) {
            let begun = run.pauses.filter { $0.start <= point.timestamp }
            if begun.contains(where: { $0.end.map { point.timestamp < $0 } ?? true }) { continue }
            if begun.count != segment {
                result.append([])
                segment = begun.count
            }
            result[result.count - 1].append(point)
        }
        return result
    }

    private static func segmentLength(_ points: [RecordedRun.RoutePoint]) -> Double {
        zip(points, points.dropFirst()).reduce(0.0) { $0 + meters($1.0, $1.1) }
    }

    /// Haversine distance on the mean Earth radius.
    static func meters(_ a: RecordedRun.RoutePoint, _ b: RecordedRun.RoutePoint) -> Double {
        let radius = 6_371_008.8
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * radius * asin(min(1, sqrt(h)))
    }

    /// Walks the sorted samples once across sorted points; `index` carries the
    /// position between calls.
    private static func nearestHeartRate(
        to time: Date,
        in samples: [RecordedRun.HeartRateSample],
        from index: inout Int
    ) -> Int? {
        guard !samples.isEmpty else { return nil }
        while index + 1 < samples.count,
              abs(samples[index + 1].timestamp.timeIntervalSince(time))
                <= abs(samples[index].timestamp.timeIntervalSince(time)) {
            index += 1
        }
        let sample = samples[index]
        guard abs(sample.timestamp.timeIntervalSince(time)) <= heartRateMatchWindow,
              sample.beatsPerMinute.isFinite, sample.beatsPerMinute > 0 else { return nil }
        return Int(sample.beatsPerMinute.rounded())
    }

    private static func coordinate(_ value: Double) -> String {
        String(format: "%.7f", value)
    }

    private static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// ISO8601DateFormatter is thread-safe, so one instance serves every point.
    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        timestampFormatter.string(from: date)
    }
}
