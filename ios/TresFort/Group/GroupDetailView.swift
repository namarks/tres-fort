import SwiftUI

/// Motivational home for a single group: a "this week" strip of per-member
/// activity-dot rows on top, the activity feed below, a "+" FAB to log a
/// manual activity, and a gear (routed through the parent) for per-group
/// settings.
struct GroupDetailView: View {
    let group: GroupSummary
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel

    @State private var showActivity = false
    @State private var selectedItem: FeedItem?
    /// Week / Month / Year zoom for the activity strip. Toggling is instant
    /// — all three are bucketed client-side from one year-window pull.
    @State private var range: ActivityRange = .week

    /// Per-group settings are routed through the parent GroupTabView's
    /// "+" menu (binding below). Surfacing a SECOND gear in the toolbar
    /// from here would merge with GroupTabView's app-settings gear and
    /// show two identical icons — confusing UX, beta-feedback #39.
    @Binding var showGroupSettings: Bool

    var body: some View {
        // Single vertical scroll view (mirrors TodayView / HistoryView).
        // The previous layout stacked a fixed-height HORIZONTAL member
        // ScrollView above a GREEDY vertical feed ScrollView inside a
        // top-anchored VStack — two scroll views fighting for height with
        // `.refreshable` floating on the container. That never laid out
        // reliably (#41 / #44 / #45 all chased the same drift, where the
        // strip slid into the scroll bounce region: visible only while you
        // pulled, gone on release). Collapsing to ONE scroll view removes
        // the negotiation entirely — the member strip is now ordinary
        // content (MemberActivityRow) inside it.
        ZStack {
            Theme.background
            ScrollView {
                LazyVStack(spacing: 14) {
                    activitySection
                    feedSection
                }
                .padding(16)
                .padding(.bottom, 96)   // clear the floating FAB
            }
            .refreshable {
                await groupModel.refreshGroup(groupID: group.id)
            }
            .overlay(alignment: .bottomTrailing) { logActivityButton }
        }
        .sheet(isPresented: $showActivity) {
            ManualActivitySheet { pending in
                await groupModel.logActivity(pending)
            }
        }
        .sheet(isPresented: $showGroupSettings) {
            GroupSettingsView(group: group, groupModel: groupModel, auth: auth)
        }
        .sheet(item: $selectedItem) { item in
            FeedItemDetailSheet(item: item, groupModel: groupModel)
        }
        .task(id: group.id) {
            await groupModel.refreshGroup(groupID: group.id)
        }
    }

    // MARK: - Activity section (week / month / year zoom)

    /// One MemberActivityRow per member (you first), each a single aligned
    /// lane for the selected zoom. Rendered only once stats have loaded —
    /// they always include the caller, so this also covers the solo case;
    /// an invite row trails when the group is just you. The roster comes
    /// from /stats (avatar, name, streak); the per-day cells come from the
    /// /activity series, joined by user_id.
    @ViewBuilder
    private var activitySection: some View {
        let roster = groupModel.stats[group.id] ?? []
        if !roster.isEmpty {
            // "Me" first; everyone else keeps server order (stable).
            let members = roster.filter(\.is_me) + roster.filter { !$0.is_me }
            let series = groupModel.activitySeries[group.id] ?? []
            let seriesByUser = Dictionary(
                series.map { ($0.user_id, $0) }, uniquingKeysWith: { a, _ in a })
            rangePicker
            ForEach(members) { m in
                MemberActivityRow(
                    stat: m,
                    lane: ActivityLanes.lane(range: range, series: seriesByUser[m.user_id]),
                    range: range)
            }
            if members.count < 2 {
                inviteRow
            }
        }
    }

    private var rangePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Range", selection: $range) {
                ForEach(ActivityRange.allCases) { r in
                    Text(r.label).tag(r)
                }
            }
            .pickerStyle(.segmented)
            Text(range.caption)
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
        }
    }

    private var inviteRow: some View {
        Button {
            // Route through the hoisted binding so this opens the SAME
            // GroupSettingsView sheet as the "Group settings…" menu item
            // (Codex PR #41 P2 — pre-fix this wrote to a dead @State).
            showGroupSettings = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.muted,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 34, height: 34)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.muted)
                }
                Text("Invite someone")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.muted)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
            }
            .frame(maxWidth: .infinity)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14).fill(Theme.surface.opacity(0.5)))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed section

    @ViewBuilder
    private var feedSection: some View {
        let items = groupModel.feed[group.id] ?? []
        sectionHeader("ACTIVITY")
            .padding(.top, 6)
        if items.isEmpty {
            EmptyFeedState()
                .padding(.top, 12)
        } else {
            ForEach(items) { item in
                Button {
                    selectedItem = item
                } label: {
                    FeedItemRow(item: item)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func sectionHeader(_ text: String) -> some View {
        Text(text)
            .font(Theme.mono(11, .bold)).tracking(2)
            .foregroundStyle(Theme.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Floating action button

    private var logActivityButton: some View {
        Button {
            showActivity = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.black)
                .frame(width: 56, height: 56)
                .background(Theme.accent)
                .clipShape(Circle())
                .shadow(radius: 6, y: 2)
        }
        .padding(20)
        .accessibilityLabel("Log activity")
    }
}

/// "No activity yet" empty state. Shown the first time you open a group
/// before anyone has logged anything.
struct EmptyFeedState: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accent)
            Text("NO ACTIVITY YET")
                .font(Theme.mono(13, .bold)).tracking(1.5)
                .foregroundStyle(Theme.text)
            Text("Log a workout, ride, or pilates class.\nFriends' moves land here.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity)
    }
}
