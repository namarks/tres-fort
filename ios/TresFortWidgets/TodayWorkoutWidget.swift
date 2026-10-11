import SwiftUI
import WidgetKit

// Today's workout at a glance. The widget only reads the snapshot the app
// publishes from its own calendar projection; it never computes a schedule.
// One entry per civil day lets it turn over at midnight, and a tap opens Today.

private let accent = Color(red: 0.96, green: 0.62, blue: 0.04)
private let surface = Color(red: 0.078, green: 0.078, blue: 0.09)

struct TodayWorkoutEntry: TimelineEntry {
    let date: Date
    let day: TrainingAgendaDay?
    let next: TrainingAgendaDay?
}

struct TodayWorkoutProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayWorkoutEntry { Self.sample }

    func getSnapshot(in context: Context, completion: @escaping (TodayWorkoutEntry) -> Void) {
        if context.isPreview { return completion(Self.sample) }
        completion(entries(now: Date()).first ?? Self.sample)
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayWorkoutEntry>) -> Void) {
        // The app reloads this timeline whenever it writes a new snapshot.
        completion(Timeline(entries: entries(now: Date()), policy: .never))
    }

    private func entries(now: Date) -> [TodayWorkoutEntry] {
        let snapshot = TrainingAgendaStore.load(from: TrainingAgendaStore.sharedDefaults)
        return TrainingAgendaTimeline
            .entries(snapshot: snapshot, now: now, calendar: TrainingAgendaCalendar.calendar())
            .map { TodayWorkoutEntry(date: $0.date, day: $0.day, next: $0.next) }
    }

    static let sample = TodayWorkoutEntry(
        date: Date(),
        day: TrainingAgendaDay(date: "", status: .workout, workoutName: "Upper A",
                               exerciseNames: ["Bench Press", "Barbell Row", "Overhead Press", "Pull-Up"]),
        next: nil)
}

/// Copy shared by every family, so each says the same thing about a day.
struct TodayWorkoutPresentation {
    let entry: TodayWorkoutEntry

    var headline: String {
        guard let day = entry.day else { return "Open Très Fort" }
        switch day.status {
        case .workout, .inProgress, .completed: return day.workoutName ?? "Workout"
        case .skipped: return "Skipped"
        case .rest: return "Rest day"
        case .unavailable: return "Time off"
        case .light: return "Light training"
        }
    }

    var status: String {
        guard let day = entry.day else { return "to load today's workout" }
        switch day.status {
        case .workout:
            let count = day.exerciseNames.count
            return count == 0 ? "Ready when you are" : "\(count) exercise\(count == 1 ? "" : "s")"
        case .inProgress: return "In progress"
        case .completed: return "Done today"
        case .skipped, .rest, .unavailable, .light: return nextLine ?? "Nothing scheduled"
        }
    }

    /// For a day without a workout to do: when the next one is.
    var nextLine: String? {
        guard let next = entry.next,
              let date = TrainingAgendaCalendar.date(from: next.date, calendar: TrainingAgendaCalendar.calendar())
        else { return nil }
        let weekday = Self.weekdayFormatter.string(from: date)
        return "Next: \(weekday) · \(next.workoutName ?? "Workout")"
    }

    var inline: String {
        guard let day = entry.day else { return "Très Fort" }
        switch day.status {
        case .workout, .inProgress: return "Today: \(headline)"
        case .completed: return "Done: \(headline)"
        case .skipped, .rest, .unavailable, .light: return headline
        }
    }

    private static let weekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = TrainingAgendaCalendar.calendar()
        formatter.timeZone = .current
        formatter.dateFormat = "EEE"
        return formatter
    }()
}

struct TodayWorkoutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayWorkoutEntry

    private var presentation: TodayWorkoutPresentation { TodayWorkoutPresentation(entry: entry) }

    var body: some View {
        content
            .widgetURL(TrainingAgendaLink.todayURL)
            .containerBackground(for: .widget) {
                switch family {
                case .accessoryInline, .accessoryCircular, .accessoryRectangular: Color.clear
                default: surface
                }
            }
    }

    @ViewBuilder private var content: some View {
        switch family {
        case .accessoryInline:
            Text(presentation.inline)
        case .accessoryRectangular:
            VStack(alignment: .leading, spacing: 1) {
                Text("TODAY").font(.caption2.weight(.bold))
                Text(presentation.headline).font(.headline).lineLimit(1)
                Text(presentation.status).font(.caption).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                summary
                if let day = entry.day, day.status == .workout || day.status == .inProgress,
                   !day.exerciseNames.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(day.exerciseNames.prefix(4), id: \.self) { name in
                            Text(name).font(.caption).foregroundStyle(.white.opacity(0.85)).lineLimit(1)
                        }
                        if day.exerciseNames.count > 4 {
                            Text("+ \(day.exerciseNames.count - 4) more")
                                .font(.caption).foregroundStyle(.white.opacity(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        default:
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TODAY")
                .font(.caption2.weight(.heavy)).tracking(1.5)
                .foregroundStyle(accent)
            Text(presentation.headline)
                .font(.headline).foregroundStyle(.white)
                .lineLimit(3).minimumScaleFactor(0.8)
            Spacer(minLength: 0)
            Text(presentation.status)
                .font(.caption.weight(.semibold))
                .foregroundStyle(entry.day?.status == .completed ? accent : .white.opacity(0.7))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }
}

struct TodayWorkoutWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: TrainingAgendaStore.widgetKind, provider: TodayWorkoutProvider()) { entry in
            TodayWorkoutWidgetView(entry: entry)
        }
        .configurationDisplayName("Today's workout")
        .description("See today's workout, or when the next one is, and open Today with a tap.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryRectangular, .accessoryInline])
    }
}
