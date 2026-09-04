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

// Embedded inside the merged History tab (see HistoryView) — owns no nav
// chrome (no NavigationStack/title; the parent's stack handles navigation).
// Self-owned `monthAnchor` plus an in-header "TODAY" button; the feed's scroll
// offset drives the condense morph.
struct CalendarMonthView: View {
    @ObservedObject var sync: SyncModel

    /// First day of the displayed month (anchored to its 1st). Self-owned now
    /// — the in-calendar "Today" button resets it; prev/next arrows shift it.
    @State private var monthAnchor: Date = CalendarMonthView.currentMonth()
    @State private var selectedDate: String?      // YYYY-MM-DD → agenda sheet
    /// Drives the morph: false → full month grid header; true → condensed
    /// contribution-heatmap "hub". Flipped by the feed's scroll offset.
    @State private var collapsed = false

    private var cal: Calendar { CalendarProjection.calendar }
    private let feedSpace = "history-feed"

    static func currentMonth() -> Date {
        let cal = CalendarProjection.calendar
        return cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }

    // ONE calendar surface that condenses, not two stacked views: a fixed
    // header that morphs month grid ⇄ heatmap as the feed scrolls beneath it.
    // GeometryReader gives the feed a min-height floor (see feedScroll) so
    // condensing never makes a short feed fit and snap the scroll back.
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                calendarHub
                feedScroll(availableHeight: geo.size.height)
            }
        }
        .sheet(item: Binding(
            get: { selectedDate.map(IdentifiedDate.init) },
            set: { selectedDate = $0?.id })
        ) { wrapped in
            DayAgendaView(sync: sync, dateString: wrapped.id)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .task { if sync.plan == nil { await sync.load() } }
    }

    // MARK: morphing calendar header

    /// ONE calendar surface that DENSIFIES on scroll — the SAME full-width month
    /// grid throughout. As `collapsed` flips, each row's cells shrink and swap
    /// their date number + glyph for a centered activity chip (see `dayCell`).
    /// Full-width + column-aligned in both states, so the condensed grid merges
    /// seamlessly into the full calendar, one row at a time.
    private var calendarHub: some View {
        VStack(spacing: 0) {
            header
            // Full width — aligns with the grid in BOTH states (the condensed
            // grid is full-width too), so it stays put through the merge.
            weekdayHeader
            grid
                .padding(.bottom, collapsed ? 10 : 12)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
        .overlay(alignment: .bottom) {
            if collapsed { Rectangle().fill(Theme.surface2).frame(height: 1) }
        }
        // Container-level fallback animation for the padding/hairline; each grid
        // row carries its own delayed animation, which overrides this for the
        // staggered one-row-at-a-time merge.
        .animation(.easeInOut(duration: 0.3), value: collapsed)
    }

    // MARK: feed (scrolls beneath the calendar; its offset drives the morph)

    @ViewBuilder
    private func feedScroll(availableHeight: CGFloat) -> some View {
        if #available(iOS 18.0, *) {
            // Reliable path: read the scroll offset directly.
            ScrollView {
                feedContent(availableHeight)
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action: { _, y in
                updateCollapsed(scrolled: y)
            }
        } else {
            // iOS 17 fallback: derive offset from a named-space GeometryReader.
            ScrollView {
                feedContent(availableHeight)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: geo.frame(in: .named(feedSpace)).minY)
                        }
                    )
            }
            .coordinateSpace(name: feedSpace)
            .onPreferenceChange(ScrollOffsetKey.self) { minY in
                updateCollapsed(scrolled: -minY)
            }
        }
    }

    private func feedContent(_ availableHeight: CGFloat) -> some View {
        LazyVStack(spacing: 12) {
            feed
        }
        .padding(.top, 12)
        .padding(.bottom, 28)
        // Floor the content above the full available height so condensing
        // (which frees ~360pt) can never make a short feed suddenly fit the
        // taller viewport and snap the scroll back to 0 — which would bounce
        // the calendar open again. The max(…, 600) guards the first layout pass,
        // where the outer GeometryReader hasn't measured yet (availableHeight 0)
        // — without it an empty feed visibly jumps height on the second frame.
        .frame(minHeight: max(availableHeight, 600) + 120, alignment: .top)
    }

    /// Flip the morph from the feed's scroll distance. Hysteresis band (6…28)
    /// keeps it from fluttering right at the threshold. No `withAnimation` here
    /// — the per-row `.animation(value: collapsed)` modifiers own the staggered
    /// transition so the rows merge one at a time.
    private func updateCollapsed(scrolled: CGFloat) {
        let next = collapsed ? (scrolled > 6) : (scrolled > 28)
        if next != collapsed { collapsed = next }
    }

    // MARK: activity log (condensed heatmap + feed)

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

    private var monthTitle: String {
        let f = DateFormatter()
        f.calendar = cal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMMM yyyy"
        return f.string(from: monthAnchor).uppercased()
    }

    private func shiftMonth(_ delta: Int) {
        if let d = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = d
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
            Button { withAnimation { monthAnchor = Self.currentMonth() } } label: {
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

    /// Condensed day-square side (and its expanded counterpart's height). The
    /// morph tweens between these. Cells stay FULL WIDTH (flexible columns,
    /// column-aligned with the expanded grid) in BOTH states — only the height
    /// and the cell contents change — so the condensed grid merges cell-for-cell
    /// into the full calendar. Validated in an HTML prototype (28pt rows, 18pt
    /// chips, 6pt gaps → a clean full-width activity grid).
    private var cellHeight: CGFloat { collapsed ? 20 : 56 }
    /// Horizontal gap is CONSTANT so condensed columns stay aligned with the
    /// expanded grid; the vertical gap tightens when condensed for density.
    private let colGap: CGFloat = 6
    private var rowGap: CGFloat { collapsed ? 3 : 6 }

    /// gridDays chunked into calendar weeks (rows of 7).
    private var gridRows: [[Date?]] {
        let days = gridDays
        return stride(from: 0, to: days.count, by: 7).map {
            Array(days[$0 ..< min($0 + 7, days.count)])
        }
    }

    /// The month grid — full width in both states, so the condensed heatmap
    /// lines up cell-for-cell with the expanded calendar. Each row animates on
    /// its OWN slightly-delayed beat off `collapsed`, so the calendar merges
    /// with / peels away from the feed ONE ROW AT A TIME instead of all at once.
    private var grid: some View {
        VStack(spacing: rowGap) {
            ForEach(Array(gridRows.enumerated()), id: \.offset) { rowIndex, row in
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
                .animation(.easeInOut(duration: 0.3).delay(Double(rowIndex) * 0.06),
                           value: collapsed)
            }
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder private func dayCell(_ date: Date) -> some View {
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
        // matching the condensed dots, the feed, and the Group heatmap
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
        // Condensed dots = the day's activity CATEGORIES, one dot per category,
        // so a multi-sport day (e.g. lift + ride) shows ALL of them rather than
        // collapsing to one dominant color. Order: lift (its state color —
        // green=done / amber=planned/active) or skip (red), then endurance
        // (cyan), then manual (its OWN category color via forActivityKind — so a
        // manual run/ride reads cyan, matching the expanded glyph + the Group
        // heatmap, not a blanket purple). A bare planned ride is muted. Duplicate
        // categories collapse to one dot (a manual ride alongside an intervals
        // ride → a single cyan dot). Empty array → rest/empty day (no dot).
        let dayColors: [Color] = {
            var out: [Color] = []
            if isWorkout, let c = st?.color { out.append(c) }
            else if isSkipped { out.append(Theme.danger) }
            if hasEndurance {
                if hasActivity { out.append(WorkoutCategory.endurance.color) }
                if hasManual {
                    let c = WorkoutCategory.forActivityKind(
                        dayManual.first?.type ?? "other").color
                    if !out.contains(c) { out.append(c) }
                }
                if out.isEmpty && hasRide { out.append(Theme.muted) }
            }
            return out
        }()

        Button {
            selectedDate = ymd
        } label: {
            // Two stacked backings cross-fade so the box recolors cleanly from
            // the expanded surface to a uniform faint condensed box. Everything
            // else (ring, chip, number, glyph, badges) is an OVERLAY, so the
            // grid's .frame is the SOLE size source — the cell can never be
            // stretched taller than its frame by the text's intrinsic height
            // (that was the "tall bars" bug).
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(isToday ? Theme.surface2
                          : (isWorkout ? Theme.surface : Theme.surface.opacity(0.35)))
                    .opacity(collapsed ? 0 : 1)
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(hex: 0x191920))
                    .opacity(collapsed ? 1 : 0)
            }
            // Today keeps its accent ring in both states (the workout tint ring
            // only shows when expanded).
            .overlay {
                RoundedRectangle(cornerRadius: collapsed ? 8 : 10)
                    .strokeBorder(isToday ? Theme.accent
                            : (!collapsed && isWorkout ? (st?.color ?? Theme.accent).opacity(0.35)
                               : Color.clear),
                            lineWidth: isToday ? 1.5 : 1)
            }
            // Condensed: a centered row of activity dots (fades in) — one dot
            // per category present, so a multi-sport day shows several dots
            // side by side. Rest/empty → no dots.
            .overlay {
                if !dayColors.isEmpty {
                    HStack(spacing: 3) {
                        ForEach(dayColors.indices, id: \.self) { i in
                            RoundedRectangle(cornerRadius: 2.5)
                                .fill(dayColors[i])
                                .frame(width: 10, height: 10)
                        }
                    }
                    .opacity(collapsed ? 1 : 0)
                }
            }
            // Expanded: date number + state glyph (fades out as it condenses).
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
                .opacity(collapsed ? 0 : 1)
                .allowsHitTesting(false)
            }
            // Corner badges belong to the full cell only — they fade out with
            // the rest of the expanded chrome.
            .overlay(alignment: .topTrailing) {
                if conflict == .clash || conflict == .heavyNextDay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(4)
                        .opacity(collapsed ? 0 : 1)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if secondaryEndurance {
                    Image(systemName: enduranceGlyph)
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(enduranceColor)
                        .padding(4)
                        .opacity(collapsed ? 0 : 1)
                }
            }
        }
        .buttonStyle(.plain)
    }

}

/// Sheet item wrapper (a YYYY-MM-DD string identifies the day).
private struct IdentifiedDate: Identifiable { let id: String }

/// Tracks the History feed's scroll offset (iOS 17-compatible — no
/// `onScrollGeometryChange`, which is 18+). The feed reports its top edge in a
/// named coordinate space; `CalendarMonthView` reads it to morph the calendar.
private struct ScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// One day in the History feed: a date block + that day's training (lift,
/// endurance, manual), color-coded by category (matching the heatmap). Tapping
/// the row opens the full DayAgendaView for the date — where all the detail
/// already lives, so the feed stays a lightweight index.
private struct ActivityFeedRow: View {
    @ObservedObject var sync: SyncModel
    let ymd: String

    private struct Item { let glyph: String; let text: String; let color: Color }

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
            Text(part("EEE").uppercased())
                .font(Theme.mono(9, .bold)).tracking(1).foregroundStyle(Theme.muted)
            Text(part("d"))
                .font(Theme.display(26)).foregroundStyle(Theme.text)
            Text(part("MMM").uppercased())
                .font(Theme.mono(9, .bold)).tracking(1).foregroundStyle(Theme.dim)
        }
        .frame(width: 46)
    }

    private func part(_ fmt: String) -> String {
        guard let d = CalendarProjection.date(from: ymd) else { return "" }
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f.string(from: d)
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
                    color: WorkoutCategory.endurance.color))
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
