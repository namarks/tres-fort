import SwiftUI

/// Motivational home for a single group: member-chip strip + feed list,
/// with a "+" FAB to log a manual activity and a gear toolbar to open
/// per-group settings.
struct GroupDetailView: View {
    let group: GroupSummary
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel

    @State private var showActivity = false
    @State private var showSettings = false
    @State private var selectedItem: FeedItem?

    /// Per-group settings are routed through the parent GroupTabView's
    /// "+" menu (binding below). Surfacing a SECOND gear in the toolbar
    /// from here would merge with GroupTabView's app-settings gear and
    /// show two identical icons — confusing UX, beta-feedback #39.
    @Binding var showGroupSettings: Bool

    var body: some View {
        ZStack {
            Theme.background
            VStack(spacing: 0) {
                memberStrip
                feedContent
            }
            .overlay(alignment: .bottomTrailing) {
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
        .refreshable {
            await groupModel.refreshGroup(groupID: group.id)
        }
        .task(id: group.id) {
            await groupModel.refreshGroup(groupID: group.id)
        }
    }

    // MARK: - Member strip

    /// Intrinsic height = MemberChip frame (110) + vert padding (14 × 2) = 138.
    /// Locking it via `.frame(height:)` is the fix for beta feedback #39 —
    /// without it, the VStack(spacing: 0) below gave the strip and the
    /// feedContent ScrollView each half of the available vertical space,
    /// which clipped the chip's avatar into a thin sliver at the bottom
    /// of an oversized strip area.
    private static let stripHeight: CGFloat = 138

    private var memberStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                let members = groupModel.stats[group.id] ?? []
                ForEach(members) { m in
                    MemberChip(stat: m)
                }
                if members.count < 2 {
                    invitePlaceholderChip
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
        }
        .frame(height: Self.stripHeight)
        .background(Theme.surface.opacity(0.5))
    }

    private var invitePlaceholderChip: some View {
        Button {
            showSettings = true
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .strokeBorder(Theme.muted,
                                      style: StrokeStyle(lineWidth: 1.5, dash: [3, 3]))
                        .frame(width: 50, height: 50)
                    Image(systemName: "person.badge.plus")
                        .font(.system(size: 18))
                        .foregroundStyle(Theme.muted)
                }
                Text("Invite")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                Text(" ")
                    .font(Theme.mono(10))
            }
            .frame(width: 80, height: 110)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Feed

    @ViewBuilder
    private var feedContent: some View {
        let items = groupModel.feed[group.id] ?? []
        if items.isEmpty {
            EmptyFeedState()
                .frame(maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            selectedItem = item
                        } label: {
                            FeedItemRow(item: item)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
                .padding(.bottom, 96)   // clear FAB
            }
        }
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
    }
}
