import Foundation

/// GPX 1.1 for a recorded run, the file intervals.icu analyzes like a watch
/// upload. Heart rate rides in the Garmin TrackPointExtension, which
/// intervals.icu and most analysis tools read.
enum RecordedRunGPX {
    /// A heart-rate sample further than this from a track point is not
    /// attached to it, so a gap in HR stays a gap instead of a stale value.
    static let heartRateMatchWindow: TimeInterval = 5

    static func encode(_ run: RecordedRun) -> Data {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Tres Fort" xmlns="http://www.topografix.com/GPX/1/1" \
        xmlns:gpxtpx="http://www.garmin.com/xmlschemas/TrackPointExtension/v1">
          <metadata><time>\(timestamp(run.startedAt))</time></metadata>
          <trk>
            <name>\(escape(run.name ?? "Run"))</name>
            <type>running</type>
            <trkseg>

        """
        let heartRates = run.heartRates.sorted { $0.timestamp < $1.timestamp }
        var hrIndex = 0
        for point in run.points.sorted(by: { $0.timestamp < $1.timestamp }) {
            xml += "      <trkpt lat=\"\(coordinate(point.latitude))\" lon=\"\(coordinate(point.longitude))\">"
            if let altitude = point.altitude, altitude.isFinite {
                xml += "<ele>\(String(format: "%.1f", altitude))</ele>"
            }
            xml += "<time>\(timestamp(point.timestamp))</time>"
            if let bpm = nearestHeartRate(to: point.timestamp, in: heartRates, from: &hrIndex) {
                xml += "<extensions><gpxtpx:TrackPointExtension><gpxtpx:hr>\(bpm)</gpxtpx:hr>"
                    + "</gpxtpx:TrackPointExtension></extensions>"
            }
            xml += "</trkpt>\n"
        }
        xml += """
            </trkseg>
          </trk>
        </gpx>

        """
        return Data(xml.utf8)
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

    static func escape(_ text: String) -> String {
        var out = ""
        for ch in text {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}
