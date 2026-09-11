import SwiftUI

struct CoachingContextView: View {
    @ObservedObject var sync: SyncModel
    @Environment(\.dismiss) private var dismiss
    private var today: String { CalendarProjection.dateString(Date()) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if sync.isUsingCachedState { CachedStateBanner() }
                    Text("Recorded training and your authored plan settings. Your coach reads the same source data.")
                        .font(Theme.mono(12)).foregroundStyle(Theme.muted)
                    if let plan = sync.plan {
                        Text("\(plan.name) · version \(plan.version)").font(Theme.display(22))
                        let meta = CoachingContext.planMeta(plan.meta)
                        DisclosureGroup("Schedule and plan context") {
                            VStack(alignment: .leading, spacing: 12) {
                                ForEach(PlanSchedule.weekdayKeys, id: \.self) { day in
                                    let id = plan.schedule?.templateID(forWeekdayKey: day)
                                    let name = id.flatMap { id in plan.workouts.first { $0.id == id }?.name }
                                    Text("\(day.capitalized): \(plan.schedule == nil ? "Unknown" : name ?? (id == nil ? "Rest" : "Unknown workout"))")
                                }
                                ForEach(["race", "periodization", "trips", "stress_model"], id: \.self) { key in
                                    let value = meta[key] ?? .null
                                    Text("\(key.replacingOccurrences(of: "_", with: " ").capitalized): \(value == .null ? "Not recorded" : value.displayText)")
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }.padding(.top, 8)
                        }.accessibilityIdentifier("coaching.plan")
                    } else { Text("Plan context unavailable") }
                    let recent = CoachingContext.recent(sync.sessions, through: today)
                    let last = CoachingContext.lastCompleted(sync.sessions, through: today)
                    if let last, !recent.contains(where: { $0.id == last.id }) {
                        Text("Last completed workout").font(Theme.display(20))
                        session(last)
                    }
                    Text("Recent sessions").font(Theme.display(20))
                    if recent.isEmpty { Text("No recorded sessions available") }
                    ForEach(recent) { row in session(row) }
                    Text("Logged working sets exclude warm-ups and count each logged set once. Muscle counts use only the catalog’s primary muscle; they do not measure stimulus or complete muscle volume. Effort coverage counts recorded set RPE. External-load volume excludes timed, assisted and zero-load work; units stay separate.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                    Text("Planned endurance and scheduling context are available in the calendar. Conflict flags use fixed load/duration thresholds, not a recovery or safety assessment. Missing values remain unknown.")
                        .font(Theme.mono(11)).foregroundStyle(Theme.muted)
                }.padding(20).foregroundStyle(Theme.text)
            }
            .background(Theme.background).navigationTitle("Training overview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }.preferredColorScheme(.dark)
    }

    private func session(_ row: SessionRow) -> some View {
        let context = CoachingContext.session(row, sets: sync.sets, catalog: sync.catalog)
        return DisclosureGroup("\(row.date) · \(row.status.replacingOccurrences(of: "_", with: " "))") {
            VStack(alignment: .leading, spacing: 8) {
                Text("\(context.logged_working_sets) logged working sets · effort recorded for \(context.sets_with_effort)")
                ForEach(context.primary_muscle_sets, id: \.muscle) { muscle in
                    Text("\(muscle.muscle): \(muscle.logged_working_sets) sets (primary muscle)")
                }
                ForEach(context.external_load_volume, id: \.unit) { volume in
                    Text("\(CoachingContext.number(volume.value)) \(volume.unit)·reps external-load volume · \(volume.contributing_sets) contributing sets")
                }
                if context.external_load_volume.isEmpty { Text("External-load volume unavailable") }
                SavedWorkoutFeedbackView(feedback: WorkoutFeedback(notes: row.notes, perceivedFatigue: row.perceived_fatigue))
                Text("Best recorded set per comparable load and mode; not a personal-record claim.")
                    .foregroundStyle(Theme.muted)
                ForEach(context.sets) { set in Text(set.label) }
            }.font(Theme.mono(12)).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }.font(Theme.mono(12)).accessibilityIdentifier("coaching.session." + row.id)
    }
}
