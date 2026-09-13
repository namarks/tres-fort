import SwiftUI

/// Detail uses the current visible feed, so revoked sharing cannot leave an
/// old snapshot open. Other members can be reported or blocked; the caller
/// can delete their own manual activities.
struct FeedItemDetailSheet: View {
    let item: FeedItem
    let groupID: String
    @ObservedObject var groupModel: GroupModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Theme.bg.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let item = groupModel.feed[groupID]?.first(where: { $0.id == self.item.id }) {
                        switch item {
                        case .session(let s):  SessionDetail(item: s)
                        case .ride(let r):     RideDetail(item: r)
                        case .activity(let a): ActivityDetail(item: a, groupModel: groupModel, dismiss: { dismiss() })
                        case .unknown(let u):  UnknownDetail(item: u)
                        }
                        if !item.isMe {
                            HStack {
                                Text("Report or block")
                                Spacer()
                                GroupMemberSafetyActions(report: .init(groupID: groupID, memberID: item.userID,
                                    itemID: item.id, itemType: item.reportType), model: groupModel)
                            }
                        }
                    } else {
                        Text("This shared activity is no longer available.")
                    }
                }
                .padding(22)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Per-case sections

    private struct SessionDetail: View {
        let item: FeedSessionItem
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(item.user_display_name) · \(item.session.day_name ?? "STRENGTH")".uppercased())
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Text(item.session.day_label.map { "\($0) DAY" } ?? "STRENGTH")
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.text)
                HStack(spacing: 18) {
                    StatTile(label: "SETS", value: "\(item.session.set_count)")
                    StatTile(label: "TIME",
                             value: FeedFormat.duration(seconds: item.session.duration_sec))
                }
                Divider().overlay(Theme.dim)
                if item.session.displayTopSets.isEmpty {
                    Text("No top sets reported.")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                } else {
                    ForEach(Array(item.session.displayTopSets.enumerated()), id: \.offset) { _, s in
                        HStack(alignment: .firstTextBaseline) {
                            Text(s.exercise.uppercased())
                                .font(Theme.mono(12, .bold))
                                .foregroundStyle(Theme.text)
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(s.valueLabel)
                                    .font(Theme.mono(13))
                                    .foregroundStyle(Theme.accent)
                                if let estimate = s.estimatedOneRepMax {
                                    Text("~\(Int(estimate.rounded())) 1RM")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.dim)
                                } else if s.is_timed == true {
                                    Text("BEST HOLD AT THIS LOAD")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.dim)
                                } else if s.modality == "bw" {
                                    Text("BEST REPS AT THIS LOAD")
                                        .font(Theme.mono(9))
                                        .foregroundStyle(Theme.dim)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private struct RideDetail: View {
        let item: FeedRideItem
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(item.user_display_name) · \(item.ride.kind.uppercased())")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Text((item.ride.name ?? item.ride.kind).uppercased())
                    .font(Theme.display(34))
                    .foregroundStyle(Theme.text)
                SourceAttributionLabel(text: item.ride.source_attribution)
                HStack(spacing: 18) {
                    if let dist = FeedFormat.distance(meters: item.ride.distance_m) {
                        StatTile(label: "DIST", value: dist)
                    }
                    StatTile(label: "TIME",
                             value: FeedFormat.duration(seconds: item.ride.moving_time_sec))
                    if let w = item.ride.average_watts, w > 0 {
                        StatTile(label: "AVG", value: "\(Int(w.rounded())) W")
                    }
                }
                if let tss = item.ride.training_load {
                    Text("\(tss) TSS")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                }
                if let elev = item.ride.elevation_gain_m, elev > 0 {
                    let ft = Int((elev * 3.28084).rounded())
                    Text("\(ft) ft elevation")
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.muted)
                }
            }
        }
    }

    private struct ActivityDetail: View {
        let item: FeedActivityItem
        let groupModel: GroupModel
        let dismiss: () -> Void
        @State private var confirmDelete = false

        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text("\(item.user_display_name) · \(item.activity.kind.uppercased())")
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Text((item.activity.title ?? PendingActivity.label(for: item.activity.kind)).uppercased())
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.text)
                if let m = item.activity.duration_min {
                    StatTile(label: "TIME", value: "\(m) min")
                }
                if let notes = item.activity.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.text)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                if item.is_me {
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        HStack {
                            Spacer()
                            Image(systemName: "trash")
                            Text("Delete activity").bold()
                            Spacer()
                        }
                        .padding(.vertical, 12)
                        .background(Theme.danger.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .foregroundStyle(Theme.danger)
                    }
                    .padding(.top, 8)
                    .confirmationDialog(
                        "Delete this activity?",
                        isPresented: $confirmDelete,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            Task {
                                await groupModel.deleteActivity(id: item.id)
                                dismiss()
                            }
                        }
                        Button("Cancel", role: .cancel) {}
                    }
                }
            }
        }
    }

    private struct UnknownDetail: View {
        let item: FeedUnknownItem
        var body: some View {
            VStack(alignment: .leading, spacing: 14) {
                Text(item.user_display_name.uppercased())
                    .font(Theme.mono(11, .bold)).tracking(2)
                    .foregroundStyle(Theme.muted)
                Text("DID SOMETHING")
                    .font(Theme.display(30))
                    .foregroundStyle(Theme.text)
                // M5 chose to render a generic fallback for unknown types
                // because the alternative (crashing the decoder) is worse;
                // revisit if a specific new type warrants a proper renderer.
                Text("This activity type isn't supported by your app yet. Update to see the full details.")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private struct StatTile: View {
        let label: String
        let value: String
        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(Theme.mono(9, .bold)).tracking(1)
                    .foregroundStyle(Theme.muted)
                Text(value)
                    .font(Theme.mono(18, .bold))
                    .foregroundStyle(Theme.text)
            }
        }
    }
}
