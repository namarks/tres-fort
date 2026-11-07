import Foundation

/// TCX (Garmin Training Center v2) for a recorded run, the file intervals.icu
/// analyzes like a watch upload. TCX rather than GPX because it carries the
/// workout builder's totals: the lap holds moving time and distance, and each
/// track point holds a cumulative distance scaled to that total, so the
/// uploaded run matches what the recorder showed. Each pause starts a new
/// track, and the distance covered while paused never counts. Altitude
/// follows the barometer when the run has its readings (P7), set at the
/// level GPS measured, so hills don't shimmer with GPS noise.
enum RecordedRunTCX {
    /// A heart-rate sample further than this from a track point is not
    /// attached to it, so a gap in HR stays a gap instead of a stale value.
    static let heartRateMatchWindow: TimeInterval = 5

    static func encode(_ run: RecordedRun) -> Data {
        let tracks = segments(run)
        let gpsDistance = tracks.reduce(0.0) { $0 + segmentLength($1) }
        let totalDistance = run.distanceMeters > 0 ? run.distanceMeters : gpsDistance
        let scale = gpsDistance > 0 ? totalDistance / gpsDistance : 0

        // Each point as the file states it, with its cumulative distance,
        // altitude and heart rate.
        let heartRates = run.heartRates.sorted { $0.timestamp < $1.timestamp }
        let altitudes = RunAltitude.fusedAltitudes(run, points: tracks.flatMap { $0 })
        var pointIndex = 0
        var hrIndex = 0
        var distance = 0.0
        let encoded: [[FilePoint]] = tracks.map { track -> [FilePoint] in
            track.enumerated().map { (i, point) -> FilePoint in
                if i > 0 { distance += meters(track[i - 1], point) * scale }
                let altitude = altitudes.map { $0[pointIndex] } ?? point.altitude
                pointIndex += 1
                return FilePoint(point: point, distance: distance, altitude: altitude,
                                 heartRate: nearestHeartRate(to: point.timestamp, in: heartRates, from: &hrIndex))
            }
        }

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2">
          <Activities>
            <Activity Sport="Running">
              <Id>\(timestamp(run.startedAt))</Id>

        """
        for lap in fileLaps(run, tracks: encoded, totalDistance: totalDistance) {
            xml += "      <Lap StartTime=\"\(timestamp(lap.start))\">\n"
            xml += "        <TotalTimeSeconds>\(decimal(lap.seconds))</TotalTimeSeconds>\n"
            xml += "        <DistanceMeters>\(decimal(lap.meters))</DistanceMeters>\n"
            xml += "        <Calories>0</Calories>\n"
            if let average = lap.averageHeartRate {
                xml += "        <AverageHeartRateBpm><Value>\(average)</Value></AverageHeartRateBpm>\n"
            }
            if let maximum = lap.maxHeartRate {
                xml += "        <MaximumHeartRateBpm><Value>\(maximum)</Value></MaximumHeartRateBpm>\n"
            }
            xml += "        <Intensity>\(lap.intensity)</Intensity>\n"
            xml += "        <TriggerMethod>\(lap.trigger)</TriggerMethod>\n"
            for track in lap.tracks {
                xml += "        <Track>\n"
                for point in track {
                    xml += "          <Trackpoint><Time>\(timestamp(point.point.timestamp))</Time>"
                    xml += "<Position><LatitudeDegrees>\(coordinate(point.point.latitude))</LatitudeDegrees>"
                    xml += "<LongitudeDegrees>\(coordinate(point.point.longitude))</LongitudeDegrees></Position>"
                    if let altitude = point.altitude, altitude.isFinite {
                        xml += "<AltitudeMeters>\(decimal(altitude))</AltitudeMeters>"
                    }
                    xml += "<DistanceMeters>\(decimal(point.distance))</DistanceMeters>"
                    if let bpm = point.heartRate {
                        xml += "<HeartRateBpm><Value>\(bpm)</Value></HeartRateBpm>"
                    }
                    xml += "</Trackpoint>\n"
                }
                xml += "        </Track>\n"
            }
            xml += "      </Lap>\n"
        }
        xml += """
            </Activity>
          </Activities>
        </TrainingCenterDatabase>

        """
        return Data(xml.utf8)
    }

    private struct FilePoint {
        var point: RecordedRun.RoutePoint
        var distance: Double
        var altitude: Double?
        var heartRate: Int?
    }

    private struct FileLap {
        var start: Date
        var seconds: Double
        var meters: Double
        var averageHeartRate: Int? = nil
        var maxHeartRate: Int? = nil
        var intensity = "Active"
        var trigger = "Manual"
        var tracks: [[FilePoint]] = []
    }

    /// One lap holding the whole run, or a planned run's laps (planned-runs
    /// P9), one per step, so intervals.icu shows each interval. A step that
    /// ends mid-track splits it: the next lap's track starts on the point
    /// the last one ended on, which the Worker reads as one stretch
    /// (`parseTcx`), while a pause still starts a new track.
    private static func fileLaps(_ run: RecordedRun, tracks: [[FilePoint]], totalDistance: Double) -> [FileLap] {
        let summaries = RunLaps.summaries(run)
        guard summaries.count > 1 else {
            return [FileLap(start: run.startedAt, seconds: max(run.movingSeconds, 0), meters: totalDistance,
                            tracks: tracks)]
        }
        var laps = summaries.enumerated().map { (index, summary) -> FileLap in
            var lap = FileLap(start: index == 0 ? run.startedAt : RunLaps.date(run, atMoving: summary.startSeconds),
                              seconds: summary.movingSeconds, meters: summary.meters,
                              averageHeartRate: summary.averageHeartRate, maxHeartRate: summary.maxHeartRate)
            if summary.step?.step.kind == .recovery { lap.intensity = "Resting" }
            if summary.end == .completed {
                lap.trigger = summary.step?.step.durationSeconds != nil ? "Time" : "Distance"
            }
            return lap
        }
        for track in tracks {
            var lapIndex: Int?
            var previous: FilePoint?
            for point in track {
                let moving = RunLaps.movingSeconds(run, at: point.point.timestamp)
                let index = summaries.lastIndex(where: { $0.startSeconds <= moving }) ?? 0
                if index != lapIndex {
                    // The new lap's track starts where the last lap's ended.
                    laps[index].tracks.append(previous.map { [$0] } ?? [])
                    lapIndex = index
                }
                laps[index].tracks[laps[index].tracks.count - 1].append(point)
                previous = point
            }
        }
        // A step skipped the moment it began has nothing to show.
        return laps.filter { $0.seconds >= 0.05 || $0.meters >= 0.05 || !$0.tracks.isEmpty }
    }

    /// The heart rate the Worker reads back from this file (`parseTcx` in
    /// `src/tcxFile.ts`): each track point's whole-bpm reading on moving
    /// time, at the whole second the file states, each track carrying on
    /// where the last one ended. The run summary scores load from it, so
    /// it matches the load the Worker gives the upload (P7).
    static func heartRateStream(_ run: RecordedRun) -> [(t: Double, v: Double)] {
        let heartRates = run.heartRates.sorted { $0.timestamp < $1.timestamp }
        var index = 0
        var offset = 0.0
        var stream: [(t: Double, v: Double)] = []
        for track in segments(run) {
            guard let first = track.first, let last = track.last else { continue }
            let trackStart = wholeSecond(first.timestamp)
            for point in track {
                guard let bpm = nearestHeartRate(to: point.timestamp, in: heartRates, from: &index) else { continue }
                stream.append((offset + max(0, wholeSecond(point.timestamp) - trackStart), Double(bpm)))
            }
            offset += max(0, wholeSecond(last.timestamp) - trackStart)
        }
        return stream
    }

    /// The file states times to the second.
    private static func wholeSecond(_ date: Date) -> Double { date.timeIntervalSince1970.rounded(.down) }

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
