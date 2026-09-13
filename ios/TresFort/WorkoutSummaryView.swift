import SwiftUI

struct WorkoutSummaryView: View {
    @ObservedObject var sync: SyncModel
    let session: SessionRow
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let summary = sync.completionSummary(for: session.id) {
                let stats = WorkoutSummaryStats.make(summary: summary, session: session,
                    timedWorkSeconds: WorkoutSummaryStats.timedWorkSeconds(
                        sets: sync.setsForSession(session.id), isTimed: sync.isTimedSet))
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 2),
                          alignment: .leading, spacing: 20) {
                    ForEach(stats) { stat in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stat.value).font(Theme.display(34))
                                .foregroundStyle(Theme.text)
                            Text(stat.label).font(.subheadline).foregroundStyle(Theme.muted)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("workoutSummary.\(stat.id)")
                    }
                }
                if stats.contains(where: { $0.id == "volume" }) {
                    Text("Weight lifted counts added load across reps.")
                        .font(.caption).foregroundStyle(Theme.muted)
                }
                if !summary.records.isEmpty {
                    Divider().overlay(Theme.surface2)
                    DisclosureGroup {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(summary.records) { record in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(record.name).font(.subheadline.weight(.semibold))
                                    Text(record.label).font(.subheadline)
                                    Text("Previous: \(record.previous)\(record.metric == "duration" ? "s" : " reps")")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.padding(.top, 10).foregroundStyle(Theme.text)
                    } label: {
                        Label("\(summary.records.count) personal \(summary.records.count == 1 ? "record" : "records")",
                              systemImage: "trophy.fill")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("workoutSummary.records")
                }
            } else {
                Text("Workout saved. \(sync.summaryErrors[session.id] ?? "Loading completion summary…")")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                if sync.summaryErrors[session.id] != nil {
                    Button("Retry summary") { Task { await sync.loadCompletionSummary(sessionID: session.id) } }
                        .frame(minHeight: 44)
                }
            }
        }
        .task(id: "\(session.id):\(sync.summaryRevision)") {
            await sync.loadCompletionSummary(sessionID: session.id)
        }
    }
}

/// Optional analysis follows the single set-by-set workout log.
struct WorkoutTargetComparisonView: View {
    let summary: WorkoutSummary

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                if summary.targets_available {
                    let differences = summary.targets.filter(\.differs)
                    ForEach(differences) { target in
                        VStack(alignment: .leading, spacing: 3) {
                            Text("\(target.name) · \(target.actual_sets)/\(target.sets) sets")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                            if target.missed_sets > 0 { Text("\(target.missed_sets) sets not logged") }
                            if target.changed_sets > 0 { Text("\(target.changed_sets) sets with a different load, reps, duration or RPE") }
                            if target.below_target_sets > 0 { Text("\(target.below_target_sets) below the rep or duration target") }
                        }
                    }
                    if summary.targets.contains(where: { $0.comparison_available == false }) {
                        Text("Some starting targets can no longer be matched to their original slots.")
                    } else if differences.isEmpty {
                        Text("No differences recorded for the available targets.")
                    }
                } else {
                    Text("Starting targets were not recorded for this session.")
                }
            }
            .font(.caption).foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
        } label: {
            Text("Compare with starting targets")
                .font(.subheadline).foregroundStyle(Theme.muted).frame(minHeight: 44)
        }
        .accessibilityIdentifier("workoutSummary.targets")
    }
}
