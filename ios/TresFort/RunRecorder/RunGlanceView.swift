import SwiftUI

/// A number the running layout can show.
enum RunMetric: String, CaseIterable, Identifiable {
    case time
    case distance
    case pace
    case averagePace
    case heartRate

    static let glanceDefault: [RunMetric] = [.pace, .distance, .time, .heartRate]

    var id: String { rawValue }

    func title(_ unit: RunDistanceUnit) -> String {
        switch self {
        case .time: "Time"
        case .distance: unit.title
        case .pace: "Pace /\(unit.abbreviation)"
        case .averagePace: "Avg /\(unit.abbreviation)"
        case .heartRate: "Heart rate"
        }
    }
}

/// The running layout: a few large numbers to read at a glance mid-stride,
/// in place of the map. Tapping a number picks what it shows.
struct RunGlanceView: View {
    @ObservedObject var model: RunRecorderModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                ForEach(Array(model.glanceMetrics.enumerated()), id: \.offset) { index, metric in
                    if index > 0 { Divider().overlay(Theme.dim) }
                    Menu {
                        ForEach(RunMetric.allCases) { choice in
                            Button(choice.title(model.unit)) { model.glanceMetrics[index] = choice }
                        }
                    } label: {
                        field(metric, at: context.date)
                    }
                    .accessibilityIdentifier("runRecorder.glance.\(metric.rawValue)")
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func field(_ metric: RunMetric, at date: Date) -> some View {
        VStack(spacing: 0) {
            Text(value(metric, at: date))
                .font(Theme.number(88))
                .foregroundStyle(model.phase == .paused ? Theme.muted : Theme.text)
                .monospacedDigit()
                .minimumScaleFactor(0.4)
                .lineLimit(1)
            Text(metric.title(model.unit).uppercased())
                .font(Theme.mono(13))
                .foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
    }

    private func value(_ metric: RunMetric, at date: Date) -> String {
        let run = model.run
        let moving = run?.activeSeconds(at: date) ?? 0
        let meters = run?.distanceMeters ?? 0
        let unit = model.unit
        switch metric {
        case .time:
            return RunFormat.duration(moving)
        case .distance:
            return RunFormat.distance(meters, in: unit)
        case .pace:
            return RunFormat.pace(run.flatMap { RunPace.current($0, unit: unit) })
        case .averagePace:
            return RunFormat.pace(RunPace.average(movingSeconds: moving, meters: meters, unit: unit))
        case .heartRate:
            guard let sample = model.latestHeartRate, date.timeIntervalSince(sample.timestamp) < 15 else {
                return "–"
            }
            return "\(Int(sample.beatsPerMinute.rounded()))"
        }
    }
}
