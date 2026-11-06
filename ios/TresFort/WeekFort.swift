import SwiftUI

/// Today's week as a fort, in the app icon's colors: every day you trained
/// raises an orange tower, a day with training still planned (or missed)
/// stands as a dark tower, and a rest day stays low. It reads the same
/// projection, sessions and activities as the calendar cells below it.
enum WeekFort {
    enum State: Equatable { case trained, planned, rest }

    struct Day: Equatable {
        let ymd: String
        let state: State
        let isToday: Bool
    }

    /// One day's tower. Logged work wins: a completed session, an in-progress
    /// one with sets, or an activity that day. A session or schedule entry
    /// still to do, or a planned ride, is a planned tower; anything else rests.
    /// Endurance on a hard-blackout day is ignored, as the calendar does.
    static func state(kind: DayProjection.Kind,
                      loggedSets: Int,
                      hasActivity: Bool,
                      hasPlannedRide: Bool,
                      suppressesEndurance: Bool) -> State {
        if kind == .completed || (kind == .inProgress && loggedSets > 0) { return .trained }
        if hasActivity && !suppressesEndurance { return .trained }
        switch kind {
        case .planned, .projected, .inProgress: return .planned
        default: break
        }
        if hasPlannedRide && !suppressesEndurance { return .planned }
        return .rest
    }

    @MainActor
    static func days(for dates: [Date], sync: SyncModel) -> [Day] {
        let today = sync.todayString
        return dates.map { date in
            let ymd = CalendarProjection.dateString(date)
            let projection = sync.projection(for: ymd, today: today)
            let dayState = Self.state(kind: projection.kind,
                                      loggedSets: sync.loggedSetCount(forDate: ymd),
                                      hasActivity: !sync.activities(on: ymd).isEmpty
                                          || !sync.manualActivities(on: ymd).isEmpty,
                                      hasPlannedRide: !sync.rides(on: ymd).isEmpty,
                                      suppressesEndurance: projection.suppressesScheduleAndEndurance)
            return Day(ymd: ymd, state: dayState, isToday: ymd == today)
        }
    }

    /// "2 of 5 done", "5 planned", "1 done" or "Rest week".
    static func summary(_ days: [Day]) -> String {
        let trained = days.filter { $0.state == .trained }.count
        let planned = days.filter { $0.state == .planned }.count
        switch (trained, planned) {
        case (0, 0): return "Rest week"
        case (0, _): return "\(planned) planned"
        case (_, 0): return "\(trained) done"
        default: return "\(trained) of \(trained + planned) done"
        }
    }

    static func accessibilityLabel(title: String, days: [Day]) -> String {
        let trained = days.filter { $0.state == .trained }.count
        let planned = days.filter { $0.state == .planned }.count
        let total = trained + planned
        let noun = total == 1 ? "training day" : "training days"
        let range = title.lowercased()
        if total == 0 { return "\(range.capitalizedFirst): rest week" }
        return "\(range.capitalizedFirst): \(trained) of \(total) \(noun) done"
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// The navy card itself: a count line, then seven towers, Monday first.
struct WeekFortView: View {
    let title: String
    let days: [WeekFort.Day]
    @Environment(\.colorScheme) private var colorScheme

    private static let towerHeight: CGFloat = 40
    private static let restHeight: CGFloat = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(WeekFort.summary(days))
                .font(Theme.mono(12, .bold))
                .foregroundStyle(days.contains { $0.state == .trained }
                                 ? BrandPalette.fortOrangeText : BrandPalette.fortLabel)
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days, id: \.ymd) { day in
                    tower(day)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: Self.towerHeight, alignment: .bottom)
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .background(BrandPalette.fortNavy)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay {
            // On a dark page the navy card needs an edge to read as a card.
            if colorScheme == .dark {
                RoundedRectangle(cornerRadius: 14).strokeBorder(BrandPalette.fortIdle, lineWidth: 1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(WeekFort.accessibilityLabel(title: title, days: days))
        .accessibilityIdentifier("today.weekFort")
    }

    @ViewBuilder
    private func tower(_ day: WeekFort.Day) -> some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
        let height = day.state == .rest ? Self.restHeight : Self.towerHeight
        switch day.state {
        case .trained:
            shape.fill(BrandPalette.fortOrange).frame(height: height)
        case .planned, .rest:
            shape.fill(day.isToday ? Color.clear : BrandPalette.fortIdle)
                .overlay {
                    if day.isToday {
                        shape.stroke(BrandPalette.fortOrange, lineWidth: 2)
                    }
                }
                .frame(height: height)
        }
    }
}
