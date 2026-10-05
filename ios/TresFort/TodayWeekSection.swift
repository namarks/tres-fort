import SwiftUI

/// Today's look ahead: this Monday–Sunday week in the calendar's own day
/// cells, the next few days that carry a workout or planned ride, and the
/// route to the full calendar. Tapping a day opens the same date sheet the
/// calendar uses, so assigning or replacing a workout works from here too.
struct TodayWeekSection: View {
    @ObservedObject var sync: SyncModel
    let onOpenCalendar: () -> Void
    @State private var selectedDate: IdentifiedString?

    var body: some View {
        let days = Self.week(containing: sync.todayString)
        let upcoming = sync.upcomingDays()
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("THIS WEEK")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Button(action: onOpenCalendar) {
                    HStack(spacing: 4) {
                        Text("Calendar")
                        Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("today.calendar")
            }
            HStack(spacing: 6) {
                ForEach(days, id: \.self) { day in
                    VStack(spacing: 4) {
                        Text(Self.weekdayFormatter.string(from: day).uppercased())
                            .font(Theme.mono(10, .bold)).tracking(1)
                            .foregroundStyle(Theme.dim)
                            .accessibilityHidden(true)
                        CalendarDayCell(sync: sync, date: day,
                                        identifier: "today.week.\(CalendarProjection.dateString(day))") { ymd in
                            selectedDate = IdentifiedString(id: ymd)
                        }
                        .frame(height: 56)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            if !upcoming.isEmpty {
                Text("COMING UP")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                    .padding(.top, 8)
                ForEach(upcoming) { day in
                    Button { selectedDate = IdentifiedString(id: day.dateString) } label: {
                        UpcomingDayRow(sync: sync, day: day)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("today.upcoming.\(day.dateString)")
                }
            }
        }
        .sheet(item: $selectedDate) { d in
            NavigationStack {
                DayAgendaView(sync: sync, dateString: d.id)
                    .navigationTitle("Workout date")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { selectedDate = nil }
                        }
                    }
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    /// Monday through Sunday of the civil week containing `today`, on the
    /// same calendar the projection and the month grid use.
    static func week(containing today: String) -> [Date] {
        let cal = CalendarProjection.calendar
        guard let date = CalendarProjection.date(from: today) else { return [] }
        let daysSinceMonday = (cal.component(.weekday, from: date) + 5) % 7
        guard let monday = cal.date(byAdding: .day, value: -daysSinceMonday, to: date) else { return [] }
        return (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: monday) }
    }

    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()
}

/// One upcoming day: its date, the workout it resolves to, and any planned
/// ride or run. A workout whose template isn't cached still shows its date.
private struct UpcomingDayRow: View {
    @ObservedObject var sync: SyncModel
    let day: SyncModel.UpcomingDay

    var body: some View {
        HStack(spacing: 14) {
            VStack(spacing: 1) {
                Text(sync.relativeLabel(for: day.dateString).uppercased())
                    .font(Theme.mono(9, .bold)).tracking(1)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(dayNumber)
                    .font(Theme.display(26)).foregroundStyle(Theme.text)
            }
            .frame(width: 58)
            VStack(alignment: .leading, spacing: 6) {
                if day.hasWorkout {
                    HStack(spacing: 8) {
                        Image(systemName: "dumbbell.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(WorkoutCategory.lift.color)
                            .frame(width: 16)
                        Text(day.workout?.name ?? "Workout scheduled")
                            .font(Theme.mono(13, .bold)).foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    if let workout = day.workout, !workout.exercises.isEmpty {
                        Text(workout.exercises.map(\.exercise_name).joined(separator: " · "))
                            .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .padding(.leading, 24)
                    }
                }
                ForEach(day.rides) { ride in
                    HStack(spacing: 8) {
                        Image(systemName: ExternalActivity.glyph(forKind: ride.kind))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(WorkoutCategory.endurance.color)
                            .frame(width: 16)
                        Text(ride.durationLabel.map { "\(ride.displayTitle) · \($0)" } ?? ride.displayTitle)
                            .font(Theme.mono(13)).foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .contentShape(Rectangle())
    }

    private var dayNumber: String {
        guard let date = CalendarProjection.date(from: day.dateString) else { return "" }
        return String(CalendarProjection.calendar.component(.day, from: date))
    }
}
