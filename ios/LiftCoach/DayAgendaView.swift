import SwiftUI

// Milestone n — agenda tap-through (presented as a sheet from a tapped
// calendar day).
//
//   completed            → the actual logged sets, grouped by exercise.
//   workout              → the day-template name + its template_exercises
//                           targets (the internal planned-vs-projected
//                           CalendarProjection split collapses to one
//                           user-facing "Workout" here — presentation only).
//   skipped              → "Skipped".
//   rest / nothing       → "Rest day".
//
// A future date with BOTH a projection and a real session shows the real
// session — that precedence lives entirely in CalendarProjection (the
// frozen algorithm); this view only renders whatever it returns.

private func fmtWeight(_ w: Double) -> String {
    w.rounded() == w ? String(Int(w)) : String(format: "%.1f", w)
}

struct DayAgendaView: View {
    @ObservedObject var sync: SyncModel
    let dateString: String

    private var prettyDate: String {
        guard let d = CalendarProjection.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE · d MMM yyyy"
        return f.string(from: d).uppercased()
    }

    var body: some View {
        let proj = sync.projection(for: dateString)
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(proj)
                    content(proj)
                    ridesSection
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
    }

    // MARK: header

    private func header(_ proj: DayProjection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prettyDate)
                .font(Theme.mono(11, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            Text(title(proj))
                .font(Theme.display(34))
                .foregroundStyle(Theme.text)
        }
    }

    private func title(_ proj: DayProjection) -> String {
        switch proj {
        case .session(let s):
            switch s {
            case "completed":   return "COMPLETED"
            case "in_progress": return "IN PROGRESS"
            // Planned + projected collapse to one user-facing "WORKOUT"
            // (no "Planned"/"Projected" wording); prefer the template name.
            case "planned":     return planTitle ?? "WORKOUT"
            case "skipped":     return "SKIPPED"
            default:            return s.uppercased()
            }
        case .projected(let tid):
            return sync.dayTemplate(id: tid)?.title.uppercased() ?? "WORKOUT"
        case .rest:  return "REST DAY"
        case .none:  return "REST DAY"
        }
    }

    /// Template title for a real session via its day_template_id.
    private var planTitle: String? {
        sync.dayTemplate(id: realSession?.day_template_id)?.title.uppercased()
    }

    private var realSession: SessionRow? {
        sync.sessionsByDate[dateString]
    }

    // MARK: content

    @ViewBuilder private func content(_ proj: DayProjection) -> some View {
        switch proj {
        case .session(let status):
            if status == "completed" || status == "in_progress" {
                loggedSets
            } else if status == "skipped" {
                note("This workout was skipped.")
            } else {
                // planned real session → show its template targets.
                if let day = sync.dayTemplate(id: realSession?.day_template_id) {
                    templateTargets(day)
                } else {
                    note("Workout — no template details cached.")
                }
            }
        case .projected(let tid):
            if let day = sync.dayTemplate(id: tid) {
                templateTargets(day)
            } else {
                note("Workout (template unavailable).")
            }
        case .rest, .none:
            note("Rest day — nothing scheduled.")
        }
    }

    // completed / in-progress → actual logged sets, grouped by exercise.
    private var loggedSets: some View {
        let logged = realSession.map { sync.setsForSession($0.id) } ?? []
        let groups = Dictionary(grouping: logged, by: \.exercise_id)
        let orderedIDs = logged.map(\.exercise_id).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        return VStack(alignment: .leading, spacing: 12) {
            if logged.isEmpty {
                note("No sets logged.")
            } else {
                ForEach(orderedIDs, id: \.self) { exID in
                    let rows = (groups[exID] ?? []).sorted { $0.set_index < $1.set_index }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(sync.exerciseName(exID).uppercased())
                            .font(Theme.display(20))
                            .foregroundStyle(Theme.text)
                        ForEach(rows) { s in
                            HStack {
                                Text("SET \(s.set_index)")
                                    .font(Theme.mono(10, .bold)).tracking(1)
                                    .foregroundStyle(Theme.dim)
                                Spacer()
                                Text(setLine(s))
                                    .font(Theme.mono(14, .bold))
                                    .foregroundStyle(s.is_warmup == 1 ? Theme.muted : Theme.text)
                            }
                            .padding(.vertical, 7)
                            .overlay(alignment: .bottom) {
                                Divider().overlay(Theme.surface2)
                            }
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    private func setLine(_ s: SetLog) -> String {
        var parts: [String] = []
        if let d = s.duration_s, d > 0, s.weight == 0 {
            parts.append("\(d)s")                       // timed hold
        } else {
            parts.append("\(fmtWeight(s.weight)) × \(s.reps)")
        }
        if let r = s.rpe { parts.append("RPE \(fmtWeight(r))") }
        if s.is_warmup == 1 { parts.append("(warmup)") }
        return parts.joined(separator: "  ")
    }

    // planned / projected → template name + targets.
    private func templateTargets(_ day: DayTemplate) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if day.exercises.isEmpty {
                note("This template has no exercises.")
            } else {
                ForEach(day.exercises) { ex in
                    HStack(alignment: .firstTextBaseline) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ex.exercise_name.uppercased())
                                .font(Theme.display(20))
                                .foregroundStyle(Theme.text)
                            if let cues = ex.cues, !cues.isEmpty {
                                Text(cues)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.dim)
                            }
                        }
                        Spacer()
                        Text(ex.targetLabel)
                            .font(Theme.mono(14, .bold))
                            .foregroundStyle(Theme.accent)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.surface)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                }
            }
        }
    }

    // MARK: read-only ride overlay
    //
    // External events (intervals.icu etc.) for this date. READ-ONLY: no
    // buttons, no actions. When the day is also a lift conflict we show a
    // single static line — adjustments happen in the Claude app, not here
    // (mirrors the no-in-app-chat split).

    @ViewBuilder private var ridesSection: some View {
        let dayRides = sync.rides(on: dateString)   // already non-deleted
        let conflict = sync.rideConflict(for: dateString)
        // Render whenever there ARE same-day rides OR a conflict exists.
        // `.heavyNextDay` is the day BEFORE a hard ride, so `dayRides` is
        // empty BY DEFINITION (the ride is the next day) — the old
        // `!dayRides.isEmpty` guard silently hid the warning even though
        // the calendar cell shows a conflict badge. Now the explanation
        // always renders when `conflict != .none`.
        if !dayRides.isEmpty || conflict != .none {
            VStack(alignment: .leading, spacing: 10) {
                if !dayRides.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "bicycle")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Theme.muted)
                        Text("PLANNED RIDES")
                            .font(Theme.mono(11, .bold)).tracking(2)
                            .foregroundStyle(Theme.muted)
                    }

                    ForEach(dayRides) { ride in
                        rideCard(ride)
                    }
                }

                conflictMessage(conflict)
            }
        }
    }

    /// A single ride's title + stats + description card.
    private func rideCard(_ ride: ExternalEvent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(ride.displayTitle.uppercased())
                .font(Theme.display(20))
                .foregroundStyle(Theme.text)

            // Duration · TSS · IF — only the parts we have.
            let stats = rideStats(ride)
            if !stats.isEmpty {
                Text(stats)
                    .font(Theme.mono(13, .bold))
                    .foregroundStyle(Theme.accent)
            }

            if let d = ride.description, !d.isEmpty {
                Text(d)
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The hard ride on the NEXT calendar day that triggered a
    /// `.heavyNextDay` conflict, if it can still be found. Uses the SAME
    /// frozen civil-date rule + hard-thresholds as `RideConflict` (no
    /// forked logic) so this names exactly the event the conflict rule
    /// fired on. nil ⇒ render graceful text, never crash.
    private var nextDayHardRide: ExternalEvent? {
        guard let next = RideConflict.nextDateString(after: dateString) else { return nil }
        return sync.rides(on: next).first(where: RideConflict.isHard)
    }

    /// Static, read-only conflict explanation (NO action / button —
    /// adjustments happen in the Claude app, mirroring no-in-app-chat).
    /// `.clash` (same-day) keeps the original single line; `.heavyNextDay`
    /// adds the triggering next-day hard ride's context (named, with
    /// duration/TSS when available, graceful when it can't be found).
    @ViewBuilder private func conflictMessage(_ conflict: RideConflict.Severity) -> some View {
        if conflict != .none {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text(conflict == .heavyNextDay
                         ? "Hard ride the next day — ask Claude to adjust"
                         : "Conflicts with a planned ride — ask Claude to adjust")
                        .font(Theme.mono(12, .bold))
                        .foregroundStyle(Theme.accent)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Next-day hard ride context (only for .heavyNextDay).
                if conflict == .heavyNextDay {
                    if let ride = nextDayHardRide {
                        let stats = rideStats(ride)
                        Text(stats.isEmpty
                             ? "Tomorrow: \(ride.displayTitle)"
                             : "Tomorrow: \(ride.displayTitle) — \(stats)")
                            .font(Theme.mono(11, .bold))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("A hard ride is planned for the next day.")
                            .font(Theme.mono(11, .bold))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.accent.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }

    /// "1h 30m  ·  95 TSS  ·  0.78 IF" — omits any missing component.
    private func rideStats(_ ride: ExternalEvent) -> String {
        var parts: [String] = []
        if let dur = ride.durationLabel { parts.append(dur) }
        if let tss = ride.training_load { parts.append("\(tss) TSS") }
        if let iff = ride.intensity {
            parts.append(String(format: "%.2f IF", iff))
        }
        return parts.joined(separator: "  ·  ")
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(13))
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .background(Theme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }
}
