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
    @State private var showDateEditor = false

    private var prettyDate: String {
        guard let d = CalendarProjection.date(from: dateString) else { return dateString }
        let f = DateFormatter()
        f.calendar = CalendarProjection.calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEEE · d MMM yyyy"
        return f.string(from: d).uppercased()
    }

    var body: some View {
        // Capture today ONCE for the whole render: it feeds the
        // projection's past/future split AND the FIX6 inference gate in
        // `plannedDisplayDay`. `sync.todayString` is a computed var (fresh
        // `Date()` each access); separate reads across one agenda render
        // could straddle midnight and disagree. One read, one clock.
        let today = sync.todayString
        let proj = sync.projection(for: dateString, today: today)
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(proj, today: today)
                    if canEditDate(projection: proj, today: today) {
                        Button {
                            showDateEditor = true
                        } label: {
                            Label("Change this date", systemImage: "calendar.badge.clock")
                                .font(Theme.mono(13, .bold))
                                .foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 13)
                                .background(Theme.surface)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                        .disabled(sync.isRoutineMutationInFlight)
                    }
                    content(proj, today: today)
                    if let error = sync.loadError {
                        Text(error)
                            .font(Theme.mono(12))
                            .foregroundStyle(Theme.danger)
                            .accessibilityIdentifier("calendarOverrideError")
                    }
                    // On a can_train_light=false blackout the backend projects
                    // items: [] — so suppress the endurance cards here too, or a
                    // blackout day would still show training to do (Codex #61 P2).
                    if !proj.suppressesScheduleAndEndurance {
                        loggedActivitiesSection
                        completedActivitiesSection
                        ridesSection
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Change this date",
            isPresented: $showDateEditor,
            titleVisibility: .visible
        ) {
            ForEach(sync.plan?.days ?? []) { day in
                Button(day.name) {
                    Task {
                        await sync.setCalendarOverride(
                            date: dateString, dayID: day.id)
                    }
                }
                .disabled(
                    proj.suppressesScheduleAndEndurance
                        || sync.isRoutineMutationInFlight
                        || (dateString == today && sync.running))
            }
            Button("Rest day") {
                Task {
                    await sync.setCalendarOverride(date: dateString, dayID: nil)
                }
            }
            .disabled(
                proj.suppressesScheduleAndEndurance
                    || sync.isRoutineMutationInFlight
                    || (dateString == today && sync.running))
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This changes only \(prettyDate). Your recurring weekly schedule stays the same.")
        }
    }

    private func canEditDate(
        projection: DayProjection,
        today: String
    ) -> Bool {
        guard dateString >= today,
              !(dateString == today && sync.running),
              !projection.suppressesScheduleAndEndurance,
              !(sync.plan?.days.isEmpty ?? true)
        else {
            return false
        }
        guard let status = realSession?.status else { return true }
        return status != "in_progress" && status != "completed"
    }

    // MARK: header

    private func header(_ proj: DayProjection, today: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(prettyDate)
                .font(Theme.mono(11, .bold)).tracking(2)
                .foregroundStyle(Theme.muted)
            Text(title(proj, today: today))
                .font(Theme.display(34))
                .foregroundStyle(Theme.text)
        }
    }

    private func title(_ proj: DayProjection, today: String) -> String {
        switch proj {
        case .session(let s, let hardBlackoutTripType):
            let compositeTitle: (String) -> String = { title in
                hardBlackoutTripType == nil ? withBike(title) : title
            }
            switch s {
            case "completed":   return compositeTitle("COMPLETED")
            // An in-progress session with nothing logged yet records no work
            // — it's the upcoming workout, not an active one. Show its name.
            case "in_progress":
                return compositeTitle(
                    liveSetCount > 0
                        ? "IN PROGRESS"
                        : (planTitle(
                            today: today,
                            allowScheduleInference: hardBlackoutTripType == nil)
                            ?? "WORKOUT"))
            // Planned + projected collapse to one user-facing "WORKOUT"
            // (no "Planned"/"Projected" wording); prefer the template name.
            case "planned":
                return compositeTitle(
                    planTitle(
                        today: today,
                        allowScheduleInference: hardBlackoutTripType == nil)
                        ?? "WORKOUT")
            // Skipped lift was NOT performed → not "lift + bike"; no suffix.
            case "skipped":     return "SKIPPED"
            default:            return compositeTitle(s.uppercased())
            }
        case .projected(let tid):
            return withBike(sync.dayTemplate(id: tid)?.title.uppercased() ?? "WORKOUT")
        // No lift on this day: a ride/run makes it a "<noun> DAY" (a ride
        // day is not a rest day); nothing at all is a true rest day.
        case .rest, .none:
            return restOrEnduranceTitle
        // M4 (multisport) — trip days. Minimal titles so the file builds;
        // the lead should refine copy and decide how a `.light` day reads
        // when it still carries endurance. tripType is available for richer
        // wording ("ITALY — TRAVEL"). For now a plain marker.
        case .unavailable:
            return "AWAY"
        case .light:
            return restOrEnduranceTitle == "REST DAY" ? "LIGHT — AWAY" : restOrEnduranceTitle
        }
    }

    /// Suffix a LIFT-day title with " + BIKE" / "+ RUN" / … when the same
    /// date also carries a ride/run/swim — the "lift + bike" classification
    /// the user asked for. No endurance → the bare lift title, unchanged.
    private func withBike(_ liftTitle: String) -> String {
        guard let noun = sync.enduranceNoun(on: dateString) else { return liftTitle }
        return "\(liftTitle) + \(noun.uppercased())"
    }

    /// "BIKE DAY" / "PILATES DAY" / … when this no-lift date carries any
    /// endurance OR a logged manual activity, else "REST DAY". The single
    /// source for the no-lift title + note.
    private var restOrEnduranceTitle: String {
        sync.noLiftDayNoun(on: dateString).map { "\($0.uppercased()) DAY" } ?? "REST DAY"
    }

    /// Live (non-deleted) logged-set count for this date's real session.
    private var liveSetCount: Int {
        realSession.map { sync.setsForSession($0.id).count } ?? 0
    }

    /// The day template to DISPLAY for a real (planned) session on this
    /// date — the SAME shared session→schedule resolver Today / the
    /// calendar / `nextWorkout` use (FIX5's class), not a bare
    /// `day_template_id` read. When the session's own `day_template_id`
    /// is null (server drops it for an existing same-date row) this still
    /// recovers the template via the weekly schedule unless a hard blackout
    /// suppresses that schedule alongside endurance content.
    ///
    /// The schedule-inference fallback is gated EXACTLY as FIX6 gates it
    /// in `CalendarMonthView.dayCell`: `dateString >= today` — the same
    /// civil-date boundary `CalendarProjection.project` uses
    /// (`dateString < today`). For a PAST date with a null
    /// `day_template_id` this returns nil (no schedule-inferred relabel —
    /// don't reintroduce the FIX6 class in the agenda); for today/future
    /// the gate is true so a planned session resolves its template, except
    /// when `allowScheduleInference` is false for a hard blackout.
    /// `today` is supplied by the caller (captured ONCE per render in
    /// `body`, midnight-TOCTOU discipline) — title + content body share
    /// that single value rather than re-reading the computed clock.
    private func plannedDisplayDay(
        today: String,
        allowScheduleInference: Bool = true
    ) -> DayTemplate? {
        sync.sessionDisplayTemplate(
            forDateString: dateString,
            allowScheduleInference:
                allowScheduleInference && dateString >= today)
    }

    /// Template title for a real planned session (via the shared,
    /// FIX6-gated resolver above — not a bare `day_template_id`).
    private func planTitle(
        today: String,
        allowScheduleInference: Bool = true
    ) -> String? {
        plannedDisplayDay(
            today: today,
            allowScheduleInference: allowScheduleInference)?.title.uppercased()
    }

    private var realSession: SessionRow? {
        sync.sessionsByDate[dateString]
    }

    // MARK: content

    @ViewBuilder private func content(_ proj: DayProjection, today: String) -> some View {
        switch proj {
        case .session(let status, let hardBlackoutTripType):
            if status == "in_progress" && liveSetCount == 0 {
                // Phantom in-progress (sets logged then all deleted): nothing
                // was recorded, so show the planned workout's targets — not a
                // bare "no sets logged" under an "in progress" header.
                plannedContent(
                    today: today,
                    allowScheduleInference: hardBlackoutTripType == nil)
            } else if status == "completed" || status == "in_progress" {
                loggedSets
            } else if status == "skipped" {
                note("This workout was skipped.")
            } else {
                // planned real session → show its template targets.
                plannedContent(
                    today: today,
                    allowScheduleInference: hardBlackoutTripType == nil)
            }
        case .projected(let tid):
            if let day = sync.dayTemplate(id: tid) {
                templateTargets(day)
            } else {
                note("Workout (template unavailable).")
            }
        case .rest, .none:
            // A ride/run OR a logged manual activity reads "<noun> day — no
            // lift scheduled" (the ride/activity cards render below); only a
            // genuinely empty day stays "Rest day — nothing scheduled".
            if let noun = sync.noLiftDayNoun(on: dateString) {
                note("\(noun) day — no lift scheduled.")
            } else {
                note("Rest day — nothing scheduled.")
            }
        // M4 (multisport) — trip days. Minimal notes so the file builds; any
        // endurance cards for the date still render below this note. The lead
        // should refine copy (e.g. surface the trip note/type).
        case .unavailable:
            note("Away — training unavailable on this trip.")
        case .light:
            if let noun = sync.noLiftDayNoun(on: dateString) {
                note("Away — light training. \(noun) scheduled.")
            } else {
                note("Away — light training only.")
            }
        }
    }

    // planned (or phantom-empty in-progress) → the day-template targets.
    // Shared FIX6-gated resolver (not a bare day_template_id): recovers the
    // template via the weekly schedule when the session's own id is null,
    // for today/future only. Past planned w/ null id stays the graceful
    // no-template note (no schedule-inferred relabel — FIX6 class preserved).
    @ViewBuilder private func plannedContent(
        today: String,
        allowScheduleInference: Bool = true
    ) -> some View {
        if let day = plannedDisplayDay(
            today: today,
            allowScheduleInference: allowScheduleInference)
        {
            templateTargets(day)
        } else {
            note("Workout — no template details cached.")
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
        var parts: [String] = [s.valueLabel(
            timed: sync.isTimedSet(s),
            bodyweight: sync.isBodyweightExercise(s.exercise_id))]
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

    // MARK: user-logged manual activities (Pilates / walk / "lift elsewhere")
    //
    // Personal off-plan log — what the user did that wasn't on the schedule
    // and didn't go through the workout runner. Authored from the app (Log
    // activity) or MCP, keyed on the user, NOT a group: these render here
    // regardless of group membership. Distinct from the intervals.icu
    // actuals below (those are a server-reconciled cache with a frozen
    // wire contract).

    @ViewBuilder private var loggedActivitiesSection: some View {
        let logged = sync.manualActivities(on: dateString)
        if !logged.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("LOGGED ACTIVITIES")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                }
                ForEach(logged) { activity in
                    loggedActivityCard(activity)
                }
            }
        }
    }

    /// A manual activity row: kind glyph + title, then a compact line of
    /// duration + kind label, then any notes. Mirrors the visual weight of
    /// the completed-activity card below without the intervals stats grid.
    private func loggedActivityCard(_ a: ActivityRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: PendingActivity.glyph(for: a.type))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text((a.title?.isEmpty == false ? a.title! : PendingActivity.label(for: a.type))
                    .uppercased())
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.text)
            }
            HStack(spacing: 10) {
                Text(PendingActivity.label(for: a.type))
                    .font(Theme.mono(11, .bold)).tracking(1)
                    .foregroundStyle(Theme.dim)
                if let mins = a.duration_minutes, mins > 0 {
                    Text("\(mins) MIN")
                        .font(Theme.mono(11, .bold)).tracking(1)
                        .foregroundStyle(Theme.dim)
                }
            }
            if let notes = a.notes, !notes.trimmingCharacters(in: .whitespaces).isEmpty {
                Text(notes)
                    .font(Theme.mono(13))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    // MARK: read-only completed activities (intervals.icu actuals)
    //
    // COMPLETED endurance activities (rides/runs) for this date, shown as
    // "workouts completed" with the same basic stats the intervals.icu app
    // shows: duration, power, heart rate, distance, elevation, load.
    // READ-ONLY — recorded upstream, never editable here.

    @ViewBuilder private var completedActivitiesSection: some View {
        let dayActivities = sync.activities(on: dateString)   // non-deleted
        if !dayActivities.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Theme.accent)
                    Text("COMPLETED ACTIVITIES")
                        .font(Theme.mono(11, .bold)).tracking(2)
                        .foregroundStyle(Theme.muted)
                }
                ForEach(dayActivities) { activity in
                    activityCard(activity)
                }
            }
        }
    }

    /// A completed activity's title + the intervals.icu basic stats grid.
    private func activityCard(_ a: ExternalActivity) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: a.glyph)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Theme.accent)
                Text(a.displayTitle.uppercased())
                    .font(Theme.display(20))
                    .foregroundStyle(Theme.text)
            }

            let stats = activityStats(a)
            if !stats.isEmpty {
                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), alignment: .leading),
                        GridItem(.flexible(), alignment: .leading),
                    ],
                    alignment: .leading,
                    spacing: 12
                ) {
                    ForEach(stats, id: \.label) { stat in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(stat.label.uppercased())
                                .font(Theme.mono(9, .bold)).tracking(1)
                                .foregroundStyle(Theme.dim)
                            Text(stat.value)
                                .font(Theme.mono(15, .bold))
                                .foregroundStyle(Theme.text)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    /// The present (non-nil) basic stats, in display order — duration and
    /// power and heart rate first (what the user explicitly asked for).
    private func activityStats(_ a: ExternalActivity) -> [(label: String, value: String)] {
        var out: [(label: String, value: String)] = []
        if let v = a.durationLabel { out.append((label: "Duration", value: v)) }
        if let v = a.distanceLabel { out.append((label: "Distance", value: v)) }
        if let v = a.avgPowerLabel { out.append((label: "Avg Power", value: v)) }
        if let v = a.normPowerLabel { out.append((label: "Norm Power", value: v)) }
        if let v = a.hrLabel { out.append((label: "Heart Rate", value: v)) }
        if let v = a.elevationLabel { out.append((label: "Elevation", value: v)) }
        if let v = a.tssLabel { out.append((label: "Load", value: v)) }
        if let v = a.caloriesLabel { out.append((label: "Calories", value: v)) }
        return out
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
    /// `.clash` (same-day HARD) keeps the original single line;
    /// `.heavyNextDay` adds the triggering next-day hard ride's context
    /// (named, with duration/TSS when available, graceful when it can't be
    /// found). `.brick` (M4: a benign same-day EASY pairing) and `.none`
    /// render NOTHING — an intended brick is not a warning.
    @ViewBuilder private func conflictMessage(_ conflict: RideConflict.Severity) -> some View {
        if conflict == .clash || conflict == .heavyNextDay {
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
