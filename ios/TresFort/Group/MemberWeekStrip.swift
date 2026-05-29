import SwiftUI

// Visual vocabulary + per-member activity lane for the Group tab, with a
// Week / Month / Year zoom.
//
// The lane is ONE fixed-height row per member at every zoom — only the
// cell UNIT changes (day → day → week), so cross-member comparison stays a
// straight scan down aligned lanes and the layout never overflows:
//   * Week  → 7 day-dots (labeled M–S, category color)
//   * Month → ~30 day cells (dense heatmap, intensity = how much)
//   * Year  → ~52 week cells (dense heatmap)
// All three are bucketed CLIENT-side from one /activity pull (a year of
// sparse daily counts), so toggling the range never refetches.

/// Coarse activity bucket used to color a cell. Kept separate from
/// FeedItemRow's per-type glyph palette on purpose: the cell answers "what
/// KIND of training" at a glance, not "which exact activity".
enum WorkoutCategory: Hashable {
    case lift          // strength session, or a manually-logged "lift"
    case endurance     // ride / run / swim / walk / hike / cardio
    case activity      // pilates / yoga (mind-body)
    case other         // unknown / uncategorized

    var color: Color {
        switch self {
        case .lift:      return Theme.accent          // amber
        case .endurance: return Color(hex: 0x06B6D4)  // cyan
        case .activity:  return Color(hex: 0xA855F7)  // purple (matches feed row)
        case .other:     return Theme.muted
        }
    }

    /// Tie-break priority when a bucket mixes categories — show the
    /// "headline" effort (lift > endurance > activity > other).
    var rank: Int {
        switch self {
        case .lift:      return 3
        case .endurance: return 2
        case .activity:  return 1
        case .other:     return 0
        }
    }

    /// Manual-activity kind → bucket (kinds from `PendingActivity.kinds`).
    /// This is the single authority for the type→category mapping; the
    /// backend /activity endpoint stays a dumb per-source aggregator.
    static func forActivityKind(_ kind: String) -> WorkoutCategory {
        switch kind {
        case "lift":
            return .lift
        case "run", "ride", "swim", "walk", "hike", "cardio":
            return .endurance
        case "pilates", "yoga":
            return .activity
        default:
            return .other
        }
    }
}

/// The selected zoom for the activity strip.
enum ActivityRange: String, CaseIterable, Identifiable {
    case week, month, year
    var id: String { rawValue }

    var label: String {
        switch self {
        case .week:  return "Week"
        case .month: return "Month"
        case .year:  return "Year"
        }
    }

    /// Caption shown under the segmented control.
    var caption: String {
        switch self {
        case .week:  return "This week"
        case .month: return "Last 30 days"
        case .year:  return "Past year · daily"
        }
    }
}

/// One cell of a lane — a day (week/month/year) bucket.
struct LaneCell: Identifiable {
    let index: Int
    let category: WorkoutCategory?   // dominant in the bucket; nil = empty
    let intensity: Int               // total items in the bucket (heat ramp)
    let isToday: Bool                // bucket contains "today"
    let label: String?               // weekday letter (week view only)
    var id: Int { index }
}

/// A laid-out lane for a zoom: a single row of cells (week dots / month
/// heat strip), or a 7×N day grid (year — day-resolution, GitHub style, so
/// the per-day category mix shows instead of a collapsed weekly dominant).
/// The year grid: week-columns of day-cells (Mon→Sun top-to-bottom) plus a
/// parallel per-column month label (non-nil where a new month begins) for
/// the top axis.
struct YearGrid {
    let columns: [[LaneCell]]
    let monthLabels: [String?]
}

enum LaneData {
    case row([LaneCell])
    case grid(YearGrid)

    var totalIntensity: Int {
        switch self {
        case .row(let cells):
            return cells.reduce(0) { $0 + $1.intensity }
        case .grid(let g):
            return g.columns.reduce(0) { $0 + $1.reduce(0) { $0 + $1.intensity } }
        }
    }
}

/// One day-column of the week view.
struct WeekDay: Identifiable {
    let index: Int          // 0 = Monday … 6 = Sunday
    let ymd: String         // "2026-05-25"
    let letter: String      // "M" "T" "W" "T" "F" "S" "S"
    let isToday: Bool
    var id: Int { index }
}

enum GroupWeek {
    /// The seven civil dates Mon→Sun of the week containing `today`,
    /// computed with the shared civil calendar (same rule as
    /// CalendarProjection — no UTC offset games).
    static func days(today: Date = Date()) -> [WeekDay] {
        let cal = CalendarProjection.calendar
        let start = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: start)  // 1 = Sun … 7 = Sat
        let sinceMonday = (weekday + 5) % 7                 // Mon → 0 … Sun → 6
        guard let monday = cal.date(byAdding: .day, value: -sinceMonday, to: start) else {
            return []
        }
        let todayYmd = CalendarProjection.dateString(start)
        let letters = ["M", "T", "W", "T", "F", "S", "S"]
        return (0..<7).compactMap { i in
            guard let d = cal.date(byAdding: .day, value: i, to: monday) else { return nil }
            let ymd = CalendarProjection.dateString(d)
            return WeekDay(index: i, ymd: ymd, letter: letters[i], isToday: ymd == todayYmd)
        }
    }
}

/// Buckets a member's sparse daily series into lane cells for a range.
/// All bucketing is anchored to the CLIENT's civil calendar so every
/// member's cells align column-for-column (the point of the lane).
enum ActivityLanes {
    static func lane(range: ActivityRange,
                     series: MemberActivitySeries?,
                     today: Date = Date()) -> LaneData {
        let daily = dailyCounts(series)
        switch range {
        case .week:  return .row(weekCells(daily: daily, today: today))
        case .month: return .row(dayWindowCells(daily: daily, today: today, count: 30))
        case .year:  return .grid(yearGrid(daily: daily, today: today, weeks: 53))
        }
    }

    /// civil-date → per-category counts. Source→category lives here (and
    /// `WorkoutCategory.forActivityKind` for the manual log).
    private static func dailyCounts(
        _ series: MemberActivitySeries?
    ) -> [String: [WorkoutCategory: Int]] {
        var out: [String: [WorkoutCategory: Int]] = [:]
        guard let series else { return out }
        for d in series.days {
            var c: [WorkoutCategory: Int] = [:]
            if d.sessions > 0 { c[.lift, default: 0] += d.sessions }
            if d.rides > 0 { c[.endurance, default: 0] += d.rides }
            for (kind, n) in d.activities where n > 0 {
                c[WorkoutCategory.forActivityKind(kind), default: 0] += n
            }
            if !c.isEmpty { out[d.date] = c }
        }
        return out
    }

    private static func weekCells(
        daily: [String: [WorkoutCategory: Int]], today: Date
    ) -> [LaneCell] {
        GroupWeek.days(today: today).map { day in
            let counts = daily[day.ymd] ?? [:]
            return LaneCell(index: day.index,
                            category: dominant(counts),
                            intensity: counts.values.reduce(0, +),
                            isToday: day.isToday,
                            label: day.letter)
        }
    }

    private static func dayWindowCells(
        daily: [String: [WorkoutCategory: Int]], today: Date, count: Int
    ) -> [LaneCell] {
        let cal = CalendarProjection.calendar
        let start = cal.startOfDay(for: today)
        let todayYmd = CalendarProjection.dateString(start)
        return (0..<count).compactMap { i in
            // Oldest first; the rightmost cell is today.
            let offset = -(count - 1 - i)
            guard let d = cal.date(byAdding: .day, value: offset, to: start) else { return nil }
            let ymd = CalendarProjection.dateString(d)
            let counts = daily[ymd] ?? [:]
            return LaneCell(index: i,
                            category: dominant(counts),
                            intensity: counts.values.reduce(0, +),
                            isToday: ymd == todayYmd,
                            label: nil)
        }
    }

    private static let monthAbbr = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                                    "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// Year view: a 7×`weeks` day grid (one cell per civil day) so the
    /// actual per-day category mix is visible rather than collapsed to a
    /// weekly dominant. Columns are oldest→newest (last = current week);
    /// rows are Mon→Sun. Days past today are omitted so the last column
    /// stops at today (the frontier reads clearly). `monthLabels` marks
    /// the column where each month begins, for the top axis.
    private static func yearGrid(
        daily: [String: [WorkoutCategory: Int]], today: Date, weeks: Int
    ) -> YearGrid {
        let cal = CalendarProjection.calendar
        let start = cal.startOfDay(for: today)
        let weekday = cal.component(.weekday, from: start)
        let sinceMonday = (weekday + 5) % 7
        guard let thisMonday = cal.date(byAdding: .day, value: -sinceMonday, to: start) else {
            return YearGrid(columns: [], monthLabels: [])
        }
        let todayYmd = CalendarProjection.dateString(start)
        var columns: [[LaneCell]] = []
        var monthLabels: [String?] = []
        var prevMonth = -1
        for c in 0..<weeks {
            let backWeeks = -(weeks - 1 - c)
            guard let monday = cal.date(byAdding: .day, value: backWeeks * 7, to: thisMonday)
            else { continue }
            // Top axis: label a column when its (Monday's) month changes.
            let month = cal.component(.month, from: monday)
            monthLabels.append(month == prevMonth ? nil : monthAbbr[(month - 1) % 12])
            prevMonth = month
            var col: [LaneCell] = []
            for r in 0..<7 {
                guard let d = cal.date(byAdding: .day, value: r, to: monday) else { continue }
                let ymd = CalendarProjection.dateString(d)
                if ymd > todayYmd { continue }   // current week's tail — omit
                let counts = daily[ymd] ?? [:]
                col.append(LaneCell(index: c * 7 + r,
                                    category: dominant(counts),
                                    intensity: counts.values.reduce(0, +),
                                    isToday: ymd == todayYmd,
                                    label: nil))
            }
            columns.append(col)
        }
        return YearGrid(columns: columns, monthLabels: monthLabels)
    }

    /// Dominant category in a bucket: highest count wins, ties broken by
    /// category rank. nil when the bucket is empty.
    private static func dominant(_ counts: [WorkoutCategory: Int]) -> WorkoutCategory? {
        guard !counts.isEmpty else { return nil }
        return counts.max { a, b in
            a.value != b.value ? a.value < b.value : a.key.rank < b.key.rank
        }?.key
    }
}

/// One member's lane: avatar + name + range count / streak on top, the
/// zoom strip below. Header is shared across zooms; only the strip differs.
struct MemberActivityRow: View {
    let stat: MemberStat
    let lane: LaneData
    let range: ActivityRange

    /// Total items in the visible range (range-aware; the dots/cells show
    /// the same activity it counts).
    private var rangeCount: Int { lane.totalIntensity }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            strip
        }
        .frame(maxWidth: .infinity)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.surface))
    }

    private var header: some View {
        HStack(spacing: 10) {
            ZStack {
                Avatar(
                    initials: stat.avatar_initials.isEmpty
                        ? avatarInitials(from: stat.display_name)
                        : stat.avatar_initials,
                    color: .stableAvatarColor(forUserID: stat.user_id))
                    .frame(width: 34, height: 34)
                if stat.is_me {
                    Circle()
                        .strokeBorder(Theme.accent, lineWidth: 2)
                        .frame(width: 38, height: 38)
                }
            }
            Text(stat.display_name)
                .font(Theme.mono(13, .bold))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 8)
            Text("\(rangeCount)")
                .font(Theme.mono(14, .bold))
                .foregroundStyle(rangeCount == 0 ? Theme.muted : Theme.text)
            if stat.streak_days > 0 {
                HStack(spacing: 2) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.accent)
                    Text("\(stat.streak_days)")
                        .font(Theme.mono(11, .bold))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
    }

    @ViewBuilder
    private var strip: some View {
        switch lane {
        case .row(let cells) where range == .week:
            // Labeled day-dots — the original week look.
            HStack(spacing: 0) {
                ForEach(cells) { cell in
                    VStack(spacing: 5) {
                        Text(cell.label ?? " ")
                            .font(Theme.mono(9, .bold))
                            .foregroundStyle(cell.isToday ? Theme.accent : Theme.dim)
                        WeekDot(category: cell.category, isToday: cell.isToday)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        case .row(let cells):
            // Month: dense single-row day heatmap.
            HStack(spacing: 2) {
                ForEach(cells) { cell in
                    HeatCell(category: cell.category,
                             intensity: cell.intensity,
                             isToday: cell.isToday)
                        .frame(maxWidth: .infinity)
                }
            }
        case .grid(let g):
            // Year: 7×N day grid with a Mon/Wed/Fri weekday gutter and a
            // month axis on top so the orientation reads without guessing.
            // Top-aligned so the current week's short column ends at today.
            VStack(alignment: .leading, spacing: 3) {
                monthAxis(g.monthLabels)
                HStack(alignment: .top, spacing: Self.gridSpacing) {
                    weekdayGutter
                    ForEach(Array(g.columns.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: Self.gridSpacing) {
                            ForEach(col) { cell in
                                HeatCell(category: cell.category,
                                         intensity: cell.intensity,
                                         isToday: cell.isToday,
                                         height: Self.gridCell)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
    }

    // MARK: - Year-grid axes

    private static let gridCell: CGFloat = 6
    private static let gridSpacing: CGFloat = 1.5
    private static let gutterWidth: CGFloat = 13

    /// Mon/Wed/Fri labels down the left. Each letter overlays a clear,
    /// cell-height slot (overflowing vertically into the blank rows) so the
    /// gutter stays exactly grid-height and the rows line up 1:1.
    private var weekdayGutter: some View {
        let letters = ["M", "", "W", "", "F", "", "S"]   // Mon, Wed, Fri, Sun
        return VStack(spacing: Self.gridSpacing) {
            ForEach(0..<7, id: \.self) { r in
                Color.clear
                    .frame(width: Self.gutterWidth, height: Self.gridCell)
                    .overlay {
                        if !letters[r].isEmpty {
                            Text(letters[r])
                                .font(Theme.mono(8, .bold))
                                .foregroundStyle(Theme.muted)
                                .fixedSize()
                        }
                    }
            }
        }
    }

    /// Month abbreviations across the top, left-anchored over the column
    /// where each month begins. A leading spacer matches the weekday
    /// gutter; each column slot is `maxWidth: .infinity` like the grid
    /// columns, so the labels sit above the right weeks. `fixedSize` lets a
    /// label overflow right over the (empty) neighbor slots without
    /// disturbing alignment.
    private func monthAxis(_ labels: [String?]) -> some View {
        HStack(spacing: Self.gridSpacing) {
            Color.clear.frame(width: Self.gutterWidth, height: 10)
            ForEach(labels.indices, id: \.self) { i in
                Color.clear
                    .frame(height: 10)
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .leading) {
                        if let m = labels[i] {
                            Text(m)
                                .font(Theme.mono(8, .bold))
                                .foregroundStyle(Theme.muted)
                                .fixedSize()
                        }
                    }
            }
        }
    }
}

/// Week-view mark: a filled colored dot when the member trained, otherwise
/// an empty ring (brighter for today).
private struct WeekDot: View {
    let category: WorkoutCategory?
    let isToday: Bool

    var body: some View {
        Group {
            if let category {
                Circle().fill(category.color)
            } else {
                Circle().strokeBorder(isToday ? Theme.muted : Theme.dim, lineWidth: 1.5)
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// Month/year-view mark: a square whose hue is the dominant category and
/// whose opacity ramps with how much was logged in the bucket. Empty
/// buckets are a faint slot; today's bucket gets an accent outline.
private struct HeatCell: View {
    let category: WorkoutCategory?
    let intensity: Int
    let isToday: Bool
    var height: CGFloat = 18

    var body: some View {
        let radius: CGFloat = height > 8 ? 2 : 1
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(isToday ? Theme.accent : .clear, lineWidth: 1))
            .frame(height: height)
    }

    private var fill: Color {
        guard let category, intensity > 0 else { return Theme.muted.opacity(0.14) }
        // 1 → 0.45 … 4+ → ~1.0. Busy buckets read as solid.
        let opacity = min(1.0, 0.45 + 0.18 * Double(intensity - 1))
        return category.color.opacity(opacity)
    }
}
