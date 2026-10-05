import SwiftUI

// Milestone m — month calendar grid.
//
// Projected future workouts (from the synced plan schedule) + real past/today
// sessions (from the in-memory SyncModel cache). Tapping a date opens the
// agenda, where a member can write a one-date workout/rest exception; recurring
// schedule changes stay in Routine.

/// Per-state visual language. Each state is intentionally distinct in
/// BOTH color and glyph so they read at a glance on the scoreboard theme.
///
/// PRESENTATION-ONLY mapping. The internal `CalendarProjection` distinction
/// between `.planned` (a real future planned session) and `.projected` (a
/// weekly-schedule projection) is preserved in code and its parity contract
/// with the backend is untouched — they merely COLLAPSE to one user-facing
/// "Workout" state here (one label, one glyph). `isWorkout` marks the
/// states that should visually POP vs receding rest.
private struct StateStyle {
    let color: Color
    let glyph: String       // SF Symbol
    let label: String
    let isWorkout: Bool
}

private func style(for kind: DayProjection.Kind) -> StateStyle? {
    switch kind {
    case .completed:
        return .init(color: Theme.done, glyph: "checkmark.seal.fill",
                     label: "Completed", isWorkout: true)
    case .inProgress:
        return .init(color: Theme.accent, glyph: "bolt.fill",
                     label: "In progress", isWorkout: true)
    case .planned, .projected:
        // Collapsed: a real planned session and a schedule projection are
        // ONE thing to the user — an upcoming workout.
        return .init(color: Theme.accent, glyph: "dumbbell.fill",
                     label: "Workout", isWorkout: true)
    case .skipped:
        return .init(color: Theme.danger, glyph: "xmark.circle.fill",
                     label: "Skipped", isWorkout: false)
    case .rest:
        return .init(color: Theme.dim, glyph: "moon.zzz.fill",
                     label: "Rest", isWorkout: false)
    // M4 (multisport) — trip-aware statuses. Minimal placeholder styling so
    // the file builds; the lead should refine the glyph/label/color for a
    // travel/blackout day (and decide whether `.light` should still read as
    // an available training day). NOT a workout for the grid's purposes.
    case .unavailable:
        return .init(color: Theme.dim, glyph: "airplane",
                     label: "Away", isWorkout: false)
    case .light:
        return .init(color: Theme.dim, glyph: "airplane",
                     label: "Light", isWorkout: false)
    case .none:
        return nil
    }
}

// Embedded inside the Calendar screen (see HistoryView), which Today pushes —
// owns no nav chrome (no NavigationStack/title; the parent's stack handles
// navigation). Self-owned month selection plus an in-header "TODAY" button.
// The month grid and the activity feed share one ordinary scroll: nothing
// resizes as the member scrolls.
struct CalendarMonthView: View {
    @ObservedObject var sync: SyncModel
    var onWeeklySchedule: (() -> Void)? = nil
    var onStartWorkout: (() -> Void)? = nil

    /// A month the prev/next arrows moved to; nil shows the current month.
    /// The in-calendar "Today" button clears it.
    @State private var pinnedMonth: Date?
    /// The model's day as of the last "Today" tap; nil follows the model's
    /// clock. A tap after a date rollover changes it, so the new month and
    /// today's cell render even when no other observed state changed.
    @State private var todayTapped: String?
    @State private var selectedDate: String?      // YYYY-MM-DD → agenda sheet

    private var cal: Calendar { CalendarProjection.calendar }

    /// First day of the displayed month. The current month comes from the
    /// model's clock, the same one that marks today's cell, never a separate
    /// `Date()`.
    private var monthAnchor: Date {
        pinnedMonth ?? Self.month(containing: todayTapped ?? sync.todayString)
    }

    static func month(containing ymd: String) -> Date {
        let cal = CalendarProjection.calendar
        let day = CalendarProjection.date(from: ymd) ?? Date()
        return cal.date(from: cal.dateComponents([.year, .month], from: day))!
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                calendarHub
                feedContent
            }
        }
        .sheet(item: Binding(
            get: { selectedDate.map(IdentifiedString.init) },
            set: { selectedDate = $0?.id })
        ) { wrapped in
            NavigationStack {
                DayAgendaView(sync: sync, dateString: wrapped.id, onStartWorkout: {
                    selectedDate = nil
                    onStartWorkout?()
                })
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
        .task { if sync.plan == nil { await sync.load() } }
    }

    // MARK: calendar header

    /// The month grid, at a fixed size. It scrolls away with the feed below it.
    private var calendarHub: some View {
        // ~31 date additions per build: compute the month's cells once and
        // hand them to the grid instead of rebuilding them there.
        let days = gridDays
        return VStack(spacing: 0) {
            header
            if days.compactMap({ $0 }).contains(where: { day in
                let ymd = CalendarProjection.dateString(day)
                return !sync.projection(for: ymd).suppressesScheduleAndEndurance
                    && sync.activities(on: ymd).contains { $0.source_attribution != nil }
            }) {
                SourceAttributionLabel(text: SourceAttributionLabel.summary).padding(.bottom, 8)
            }
            weekdayHeader
            grid(days)
                .padding(.bottom, 12)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: feed (scrolls with the calendar)

    private var feedContent: some View {
        LazyVStack(spacing: 12) {
            if let onWeeklySchedule {
                Button(action: onWeeklySchedule) {
                    Label("Weekly schedule", systemImage: "calendar.badge.clock")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .accessibilityIdentifier("calendar.weeklySchedule")
            }
            feed
        }
        .padding(.top, 12)
        .padding(.bottom, 28)
    }

    // MARK: activity log (feed)

    /// Distinct civil dates (≤ today) that carry real training — a completed/
    /// in-progress session with logged sets, a completed endurance activity,
    /// or a user-logged manual activity — newest first.
    private var activityDays: [String] {
        var set = Set<String>()
        let today = sync.todayString
        for (date, s) in sync.sessionsByDate
        where s.status == "completed" || s.status == "in_progress" {
            if sync.loggedSetCount(forDate: date) > 0 { set.insert(date) }
        }
        for a in sync.activities where !a.isDeleted {
            if !sync.projection(for: a.date, today: today)
                .suppressesScheduleAndEndurance
            {
                set.insert(a.date)
            }
        }
        for m in sync.manualActivities where m.deleted_at == nil {
            if !sync.projection(for: m.date, today: today)
                .suppressesScheduleAndEndurance
            {
                set.insert(m.date)
            }
        }
        return set.filter { $0 <= today }.sorted(by: >)
    }

    @ViewBuilder private var feed: some View {
        let days = activityDays
        if days.isEmpty {
            Text("No activity logged yet — start a workout and it'll show here.")
                .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
                .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
                .padding(.horizontal, 16)
        } else {
            ForEach(days, id: \.self) { ymd in
                Button { selectedDate = ymd } label: {
                    ActivityFeedRow(sync: sync, ymd: ymd)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: month nav

    private static let monthTitleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    private var monthTitle: String {
        Self.monthTitleFormatter.string(from: monthAnchor).uppercased()
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            pinnedMonth = d
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(monthTitle)
                .font(Theme.display(30))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            Spacer(minLength: 8)
            // "Today" lives in the calendar itself now (not the nav bar), so
            // the toolbar can stay a single centered segmented control with no
            // shifting/blank trailing slot.
            Button {
                withAnimation { pinnedMonth = nil; todayTapped = sync.todayString }
            } label: {
                Text("TODAY")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.accent)
            }
            navArrow("chevron.left") { withAnimation { shiftMonth(-1) } }
            navArrow("chevron.right") { withAnimation { shiftMonth(1) } }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
    }

    private func navArrow(_ sym: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: sym)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.muted)
                .frame(width: 40, height: 40)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    private var weekdayHeader: some View {
        HStack(spacing: 6) {
            ForEach(["MON", "TUE", "WED", "THU", "FRI", "SAT", "SUN"], id: \.self) { d in
                Text(d)
                    .font(Theme.mono(10, .bold)).tracking(1)
                    .foregroundStyle(Theme.dim)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    // MARK: grid

    /// Days to render: leading blanks (Mon-based) + every day of the month.
    private var gridDays: [Date?] {
        guard
            let range = cal.range(of: .day, in: .month, for: monthAnchor),
            let first = cal.date(from: cal.dateComponents([.year, .month], from: monthAnchor))
        else { return [] }
        // weekday: 1=Sun…7=Sat → Mon-based offset 0…6.
        let wd = cal.component(.weekday, from: first)
        let leading = (wd + 5) % 7
        var cells: [Date?] = Array(repeating: nil, count: leading)
        for day in range {
            if let d = cal.date(byAdding: .day, value: day - 1, to: first) {
                cells.append(d)
            }
        }
        return cells
    }

    private let cellHeight: CGFloat = 56
    private let colGap: CGFloat = 6
    private let rowGap: CGFloat = 6

    /// gridDays chunked into calendar weeks (rows of 7).
    private func gridRows(_ days: [Date?]) -> [[Date?]] {
        stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0 ..< min($0 + 7, days.count)])
        }
    }

    /// The month grid: full width, one row per calendar week.
    private func grid(_ days: [Date?]) -> some View {
        VStack(spacing: rowGap) {
            ForEach(Array(gridRows(days).enumerated()), id: \.offset) { _, row in
                HStack(spacing: colGap) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, day in
                        Group {
                            if let day { dayCell(day) } else { Color.clear }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: cellHeight)
                    }
                    // Pad the final partial week so columns stay aligned.
                    if row.count < 7 {
                        ForEach(0 ..< (7 - row.count), id: \.self) { _ in
                            Color.clear.frame(maxWidth: .infinity).frame(height: cellHeight)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
    }

    private func dayCell(_ date: Date) -> some View {
        CalendarDayCell(sync: sync, date: date,
                        identifier: "calendar.date.\(CalendarProjection.dateString(date))") { ymd in
            selectedDate = ymd
        }
    }

}

/// One calendar day: its number, one state glyph, and corner badges for a
/// ride clash or a secondary endurance activity. Shared by the month grid and
/// Today's week strip so both read the same. The caller sizes the cell.
struct CalendarDayCell: View {
    @ObservedObject var sync: SyncModel
    let date: Date
    let identifier: String
    let onSelect: (String) -> Void

    private var cal: Calendar { CalendarProjection.calendar }

    var body: some View {
        let ymd = CalendarProjection.dateString(date)
        // Single-clock: `sync.todayString` is a computed var (fresh
        // `Date()` each access). The cell's projection ring (past/future
        // split), the today-highlight ring (`isToday`), and the A/B label
        // gate must all agree; reading the clock 3× (proj convenience
        // overload + `isToday` + inside `dayCell`) could straddle
        // midnight so e.g. `proj` resolves `ymd` as a future projected
        // workout while `isToday` is false. Capture ONCE, thread to all
        // three.
        let today = sync.todayString
        let proj = sync.projection(for: ymd, today: today)
        // An in-progress session with NOTHING logged yet (sets logged then
        // all deleted) records no work — it is not really "in progress".
        // Present it as the planned workout instead of an active one. This is
        // a VIEW-LAYER override only: the frozen CalendarProjection and the
        // ride-conflict parity still run off the raw `proj` untouched.
        let emptyInProgress = proj.kind == .inProgress
            && sync.loggedSetCount(forDate: ymd) == 0
        let st = style(for: emptyInProgress ? .planned : proj.kind)
        let isWorkout = st?.isWorkout ?? false
        let isSkipped = proj.kind == .skipped
        let isToday = ymd == today
        let dayNum = cal.component(.day, from: date)
        let suppressesEndurance = proj.suppressesScheduleAndEndurance
        let conflict = suppressesEndurance
            ? RideConflict.Severity.none
            : sync.rideConflict(for: ymd)   // .none on non-lift days
        // Endurance overlay (read-only). A COMPLETED activity (accent,
        // kind-specific glyph) outranks a PLANNED ride (muted bicycle). On a
        // NO-LIFT day the endurance glyph IS the day's identity (a bike day,
        // not a rest day); on a lift/skip day it rides along as a small
        // corner badge ("lift + bike").
        let dayActivities = sync.activities(on: ymd)
        let hasActivity = !dayActivities.isEmpty
        let hasRide = !sync.rides(on: ymd).isEmpty
        // User-logged manual activities (Pilates/walk/…) count as the day's
        // identity too: a manual-only day is NOT a rest day. Precedence for
        // the single primary glyph: completed intervals activity → logged
        // manual activity → planned ride.
        let dayManual = sync.manualActivities(on: ymd)
        let hasManual = !dayManual.isEmpty
        // A can_train_light=false blackout suppresses endurance in the grid too:
        // the backend projects items: [] and the agenda hides the cards, so the
        // cell must render the "Away" state — not fall through to a bike/activity
        // glyph (Codex #64 P2). `.light` is unaffected — endurance coexists there.
        let hasEndurance = (hasActivity || hasRide || hasManual)
            && !suppressesEndurance
        let enduranceGlyph = hasActivity
            ? (dayActivities.first?.glyph ?? "figure.run")
            : (hasManual
                ? PendingActivity.glyph(for: dayManual.first?.type ?? "other")
                : "bicycle")
        // Endurance/manual glyph color — CATEGORY-based so a completed ride
        // reads CYAN (not amber) and a manual logs its own category color,
        // matching the feed and the Group heatmap
        // everywhere. A bare planned ride stays muted. (Previously this was a
        // blanket Theme.accent, which made rides look like lifts and clashed
        // with the cyan used in every other view.)
        let enduranceColor: Color = hasActivity
            ? WorkoutCategory.endurance.color
            : (hasManual
                ? WorkoutCategory.forActivityKind(dayManual.first?.type ?? "other").color
                : Theme.muted)
        // Endurance is a secondary corner badge ONLY when a lift or skip
        // already occupies the primary marker; on a no-lift day it becomes
        // the primary glyph below.
        let secondaryEndurance = hasEndurance && (isWorkout || isSkipped)
        Button {
            onSelect(ymd)
        } label: {
            // Everything (ring, number, glyph, badges) is an OVERLAY, so the
            // grid's .frame is the SOLE size source — the cell can never be
            // stretched taller than its frame by the text's intrinsic height
            // (that was the "tall bars" bug).
            RoundedRectangle(cornerRadius: 10)
                .fill(isToday ? Theme.surface2
                      : (isWorkout ? Theme.surface : Theme.surface.opacity(0.35)))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isToday ? Theme.accent
                            : (isWorkout ? (st?.color ?? Theme.accent).opacity(0.35)
                               : Color.clear),
                            lineWidth: isToday ? 1.5 : 1)
            }
            // Date number + state glyph.
            .overlay {
                VStack(spacing: 4) {
                    Text("\(dayNum)")
                        .font(Theme.mono(13, (isToday || isWorkout) ? .bold : .medium))
                        .foregroundStyle(isToday ? Theme.accent
                                         : (isWorkout ? Theme.text : Theme.muted))
                    // ONE primary marker per day (dumbbell upcoming, checkmark
                    // done, bolt in-progress, endurance glyph for a ride/run/
                    // manual day, moon for rest).
                    if isWorkout, let st {
                        Image(systemName: st.glyph)
                            .font(.system(size: 14, weight: .bold)).foregroundStyle(st.color)
                    } else if isSkipped, let st {
                        Image(systemName: st.glyph)
                            .font(.system(size: 12)).foregroundStyle(st.color)
                    } else if hasEndurance {
                        Image(systemName: enduranceGlyph)
                            .font(.system(size: 13, weight: .bold)).foregroundStyle(enduranceColor)
                    } else if let st {
                        Image(systemName: st.glyph)
                            .font(.system(size: 12)).foregroundStyle(st.color)
                    }
                }
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topTrailing) {
                if conflict == .clash || conflict == .heavyNextDay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if secondaryEndurance {
                    Image(systemName: enduranceGlyph)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(enduranceColor)
                        .padding(4)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
    }
}


/// One day in the History feed: a date block + that day's training (lift,
/// endurance, manual), color-coded by category (matching the day cells). Tapping
/// the row opens the full DayAgendaView for the date — where all the detail
/// already lives, so the feed stays a lightweight index.
private struct ActivityFeedRow: View {
    @ObservedObject var sync: SyncModel
    let ymd: String

    private struct Item { let glyph: String; let text: String; let color: Color; var attribution: String? = nil }

    var body: some View {
        HStack(spacing: 14) {
            dateBlock
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                    HStack(spacing: 8) {
                        Image(systemName: it.glyph)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(it.color)
                            .frame(width: 16)
                        Text(it.text)
                            .font(Theme.mono(13))
                            .foregroundStyle(Theme.text)
                            .lineLimit(1)
                    }
                    SourceAttributionLabel(text: it.attribution)
                }
            }
            Spacer(minLength: 4)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.dim)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 16)
    }

    private var dateBlock: some View {
        VStack(spacing: 1) {
            Text(part(Self.weekdayPartFormatter).uppercased())
                .font(Theme.mono(9, .bold)).tracking(1).foregroundStyle(Theme.muted)
            Text(part(Self.dayPartFormatter))
                .font(Theme.display(26)).foregroundStyle(Theme.text)
            Text(part(Self.monthPartFormatter).uppercased())
                .font(Theme.mono(9, .bold)).tracking(1).foregroundStyle(Theme.dim)
        }
        .frame(width: 46)
    }

    // One formatter per field, built once, instead of three allocations
    // per feed row.
    private static let weekdayPartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE"
        return f
    }()

    private static let dayPartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "d"
        return f
    }()

    private static let monthPartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM"
        return f
    }()

    private func part(_ formatter: DateFormatter) -> String {
        guard let d = CalendarProjection.date(from: ymd) else { return "" }
        return formatter.string(from: d)
    }

    private var items: [Item] {
        var out: [Item] = []
        let suppressesEndurance = sync.projection(for: ymd)
            .suppressesScheduleAndEndurance
        if let s = sync.sessionsByDate[ymd],
           s.status == "completed" || s.status == "in_progress",
           sync.loggedSetCount(forDate: ymd) > 0 {
            let title = sync.sessionDisplayTemplate(
                forDateString: ymd, allowScheduleInference: false)?.title ?? "Workout"
            let n = sync.loggedSetCount(forDate: ymd)
            out.append(Item(glyph: "dumbbell.fill",
                            text: "\(title) · \(n) set\(n == 1 ? "" : "s")",
                            color: WorkoutCategory.lift.color))
        }
        if !suppressesEndurance {
            for a in sync.activities(on: ymd) {
                var t = a.displayTitle
                if let d = a.durationLabel { t += " · \(d)" }
                out.append(Item(
                    glyph: a.glyph,
                    text: t,
                    color: WorkoutCategory.endurance.color, attribution: a.source_attribution))
            }
            for m in sync.manualActivities(on: ymd) {
                let label = (m.title?.isEmpty == false)
                    ? m.title!
                    : PendingActivity.label(for: m.type)
                var t = label
                if let mins = m.duration_minutes, mins > 0 {
                    t += " · \(mins) min"
                }
                out.append(Item(
                    glyph: PendingActivity.glyph(for: m.type),
                    text: t,
                    color: WorkoutCategory.forActivityKind(m.type).color))
            }
        }
        return out
    }
}
