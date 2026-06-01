import SwiftUI

// Milestone m — month calendar grid.
//
// Read-only "future calendar": projected future workouts (from the synced
// plan schedule) + real past/today sessions (from the in-memory SyncModel
// cache). No schedule-write paths exist anywhere in this file.

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

struct CalendarView: View {
    @ObservedObject var sync: SyncModel

    /// First day of the currently displayed month (anchored to its 1st).
    @State private var monthAnchor: Date = CalendarProjection.calendar
        .date(from: CalendarProjection.calendar.dateComponents([.year, .month], from: Date()))!
    @State private var selectedDate: String?      // YYYY-MM-DD → agenda sheet

    private var cal: Calendar { CalendarProjection.calendar }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 0) {
                    header
                    weekdayHeader
                    grid
                    Spacer(minLength: 0)
                    legend
                }
            }
            .navigationTitle("Calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Today") { withAnimation { goToToday() } }
                        .font(Theme.mono(13, .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(item: Binding(
                get: { selectedDate.map(IdentifiedDate.init) },
                set: { selectedDate = $0?.id })
            ) { wrapped in
                DayAgendaView(sync: sync, dateString: wrapped.id)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .preferredColorScheme(.dark)
        .task { if sync.plan == nil { await sync.load() } }
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

    private func goToToday() {
        monthAnchor = cal.date(from: cal.dateComponents([.year, .month], from: Date()))!
    }

    private var header: some View {
        HStack {
            navArrow("chevron.left") { withAnimation { shiftMonth(-1) } }
            Spacer()
            Text(monthTitle)
                .font(Theme.display(30))
                .foregroundStyle(Theme.text)
            Spacer()
            navArrow("chevron.right") { withAnimation { shiftMonth(1) } }
        }
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 40)
                .onEnded { v in
                    withAnimation { shiftMonth(v.translation.width < 0 ? 1 : -1) }
                }
        )
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

    private var grid: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)
        return LazyVGrid(columns: cols, spacing: 6) {
            ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                if let day { dayCell(day) } else { Color.clear.frame(height: 56) }
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
        // overload + `isToday` + inside `dayLabel`) could straddle
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
        let conflict = sync.rideConflict(for: ymd)   // .none on non-lift days
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
        let hasEndurance = (hasActivity || hasRide || hasManual) && proj.kind != .unavailable
        let enduranceGlyph = hasActivity
            ? (dayActivities.first?.glyph ?? "figure.run")
            : (hasManual
                ? PendingActivity.glyph(for: dayManual.first?.type ?? "other")
                : "bicycle")
        // Completed work (intervals actual OR a logged manual activity) reads
        // in accent; a bare planned ride stays muted.
        let enduranceColor: Color = (hasActivity || hasManual) ? Theme.accent : Theme.muted
        // Endurance is a secondary corner badge ONLY when a lift or skip
        // already occupies the primary marker; on a no-lift day it becomes
        // the primary glyph below.
        let secondaryEndurance = hasEndurance && (isWorkout || isSkipped)

        Button {
            selectedDate = ymd
        } label: {
            VStack(spacing: 4) {
                Text("\(dayNum)")
                    .font(Theme.mono(13, (isToday || isWorkout) ? .bold : .medium))
                    .foregroundStyle(isToday ? Theme.accent
                                     : (isWorkout ? Theme.text : Theme.muted))
                // ONE primary marker per day, anchored inside the cell box
                // (the old below-the-lift endurance glyph floated against
                // the next week's row — ambiguous which day it belonged to).
                if isWorkout, let st {
                    // One consistent glyph per state (matches the legend):
                    // dumbbell for upcoming, checkmark for done, bolt for
                    // in-progress. The day_template's day_label (A/B/Push/
                    // Pull/etc.) is intentionally NOT shown — it added a
                    // second visual language on top of the state glyph and
                    // made the calendar feel noisy. Tap the cell for the
                    // full agenda (template name + exercises).
                    Image(systemName: st.glyph)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(st.color)
                } else if isSkipped, let st {
                    // Skipped lift keeps its distinct xmark (an endurance
                    // badge, if any, rides the corner overlay below).
                    Image(systemName: st.glyph)
                        .font(.system(size: 12))
                        .foregroundStyle(st.color)
                } else if hasEndurance {
                    // No lift, but a ride/run happened or is planned, or the
                    // user logged a manual activity (Pilates/walk/…) — this is
                    // an active day, not a rest day. That activity's glyph is
                    // the day's identity (replaces the rest moon).
                    Image(systemName: enduranceGlyph)
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(enduranceColor)
                } else if let st {
                    // True rest day — a small muted moon.
                    Image(systemName: st.glyph)
                        .font(.system(size: 12))
                        .foregroundStyle(st.color)
                } else {
                    // keep cell height uniform when nothing to show
                    Image(systemName: "circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.clear)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isToday ? Theme.surface2
                          : (isWorkout ? Theme.surface
                             : Theme.surface.opacity(0.35)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isToday ? Theme.accent
                            : (isWorkout ? (st?.color ?? Theme.accent).opacity(0.35)
                               : Color.clear),
                            lineWidth: isToday ? 1.5 : 1)
            )
            // Amber clash badge: a lift date that conflicts with a ride.
            // Corner triangle-ish dot, distinct from every lift glyph. Only a
            // real .clash / .heavyNextDay warrants the warning — a benign
            // same-day .brick must NOT flag (matches DayAgendaView; Codex #64 P2).
            .overlay(alignment: .topTrailing) {
                if conflict == .clash || conflict == .heavyNextDay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
                        .padding(4)
                }
            }
            // "Lift + bike": on a lift/skip day the endurance glyph rides a
            // bottom-leading corner — clearly INSIDE this day's box, never
            // floating toward the next row.
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
    }

    // MARK: legend

    private var legend: some View {
        // Planned + projected collapse to ONE "Workout" entry: dedupe by
        // label so the legend shows Completed / In progress / Workout /
        // Skipped / Rest (no "Projected").
        let kinds: [DayProjection.Kind] =
            [.completed, .inProgress, .planned, .projected, .skipped, .rest]
        var seen = Set<String>()
        let entries = kinds.compactMap { style(for: $0) }
            .filter { seen.insert($0.label).inserted }
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 10
        ) {
            ForEach(entries, id: \.label) { s in
                HStack(spacing: 6) {
                    Image(systemName: s.glyph)
                        .font(.system(size: 11))
                        .foregroundStyle(s.color)
                    Text(s.label.uppercased())
                        .font(Theme.mono(9, .bold)).tracking(0.5)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Read-only ride overlay legend (distinct from lift states).
            HStack(spacing: 6) {
                Image(systemName: "bicycle")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.muted)
                Text("RIDE")
                    .font(Theme.mono(9, .bold)).tracking(0.5)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            // Completed endurance activity (intervals.icu actuals).
            HStack(spacing: 6) {
                Image(systemName: "figure.run")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text("CARDIO DONE")
                    .font(Theme.mono(9, .bold)).tracking(0.5)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.accent)
                Text("CONFLICT")
                    .font(Theme.mono(9, .bold)).tracking(0.5)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(Theme.surface.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .padding(16)
    }
}

/// Sheet item wrapper (a YYYY-MM-DD string identifies the day).
private struct IdentifiedDate: Identifiable { let id: String }
