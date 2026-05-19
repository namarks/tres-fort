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
    case .none:
        return nil
    }
}

/// The A/B (or other) day label for the workout that resolves on `ymd`,
/// for the on-cell badge. nil when the day has no resolvable template.
@MainActor private func dayLabel(_ sync: SyncModel, _ ymd: String) -> String? {
    switch sync.projection(for: ymd) {
    case .projected(let tid):
        return sync.dayTemplate(id: tid)?.day_label
    case .session:
        // Same session→schedule inference Today uses (shared helper, no
        // forked logic) so a completed/ad-hoc session with a null
        // day_template_id on a scheduled day still shows its A/B.
        return sync.sessionDisplayTemplate(forDateString: ymd)?.day_label
    case .rest, .none:
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
        let proj = sync.projection(for: ymd)
        let st = style(for: proj.kind)
        let isWorkout = st?.isWorkout ?? false
        let isToday = ymd == sync.todayString
        let dayNum = cal.component(.day, from: date)
        let label = isWorkout ? dayLabel(sync, ymd) : nil
        // Read-only ride overlay: distinct from the lift states.
        let hasRide = !sync.rides(on: ymd).isEmpty
        let conflict = sync.rideConflict(for: ymd)   // .none on non-lift days

        Button {
            selectedDate = ymd
        } label: {
            VStack(spacing: 4) {
                Text("\(dayNum)")
                    .font(Theme.mono(13, (isToday || isWorkout) ? .bold : .medium))
                    .foregroundStyle(isToday ? Theme.accent
                                     : (isWorkout ? Theme.text : Theme.muted))
                if let st {
                    // Workout days POP: a filled accent marker carrying the
                    // A/B (day_label). Rest/skipped recede to a small muted
                    // glyph. Internal planned vs projected is irrelevant
                    // here — both render as this single "Workout" marker.
                    if isWorkout {
                        Text(label?.uppercased() ?? "")
                            .font(Theme.mono(11, .bold))
                            .foregroundStyle(.black)
                            .frame(minWidth: 22, minHeight: 18)
                            .padding(.horizontal, 5)
                            .background(
                                Capsule().fill(st.color))
                            .overlay {
                                if label == nil {
                                    Image(systemName: st.glyph)
                                        .font(.system(size: 11, weight: .bold))
                                        .foregroundStyle(.black)
                                }
                            }
                    } else {
                        Image(systemName: st.glyph)
                            .font(.system(size: 12))
                            .foregroundStyle(st.color)
                    }
                } else {
                    // keep cell height uniform when nothing to show
                    Image(systemName: "circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.clear)
                }
                // Ride glyph sits BELOW the lift state so both read at a
                // glance and the existing states are never displaced.
                if hasRide {
                    Image(systemName: "bicycle")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Theme.muted)
                } else {
                    Image(systemName: "bicycle")
                        .font(.system(size: 10, weight: .bold))
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
            // Corner triangle-ish dot, distinct from every lift glyph.
            .overlay(alignment: .topTrailing) {
                if conflict != .none {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(Theme.accent)
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
