import SwiftUI

// Milestone m — month calendar grid.
//
// Read-only "future calendar": projected future workouts (from the synced
// plan schedule) + real past/today sessions (from the in-memory SyncModel
// cache). No schedule-write paths exist anywhere in this file.

/// Per-state visual language. Each state is intentionally distinct in
/// BOTH color and glyph so they read at a glance on the scoreboard theme.
private struct StateStyle {
    let color: Color
    let glyph: String       // SF Symbol
    let label: String
}

private func style(for kind: DayProjection.Kind) -> StateStyle? {
    switch kind {
    case .completed:
        return .init(color: Theme.done, glyph: "checkmark.seal.fill", label: "Completed")
    case .inProgress:
        return .init(color: Theme.accent, glyph: "bolt.fill", label: "In progress")
    case .planned:
        return .init(color: Theme.accent, glyph: "calendar.badge.clock", label: "Planned")
    case .projected:
        return .init(color: Theme.muted, glyph: "circle.dashed", label: "Projected")
    case .skipped:
        return .init(color: Theme.danger, glyph: "xmark.circle.fill", label: "Skipped")
    case .rest:
        return .init(color: Theme.dim, glyph: "moon.zzz.fill", label: "Rest")
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
        let proj = sync.projection(for: ymd)
        let st = style(for: proj.kind)
        let isToday = ymd == sync.todayString
        let dayNum = cal.component(.day, from: date)

        Button {
            selectedDate = ymd
        } label: {
            VStack(spacing: 4) {
                Text("\(dayNum)")
                    .font(Theme.mono(13, isToday ? .bold : .medium))
                    .foregroundStyle(isToday ? Theme.accent : Theme.text)
                if let st {
                    Image(systemName: st.glyph)
                        .font(.system(size: 13))
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
                    .fill(isToday ? Theme.surface2 : Theme.surface.opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(isToday ? Theme.accent : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: legend

    private var legend: some View {
        let kinds: [DayProjection.Kind] =
            [.completed, .inProgress, .planned, .projected, .skipped, .rest]
        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3),
            spacing: 10
        ) {
            ForEach(kinds.compactMap { k -> StateStyle? in style(for: k) }, id: \.label) { s in
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
