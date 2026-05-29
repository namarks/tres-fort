import SwiftUI

/// Root of the Group tab. Routes on `groupModel.phase`:
///   * `.loading`    → spinner
///   * `.error(msg)` → error state with Retry
///   * `.none`       → big "Join with code" / "Create group" CTAs
///   * `.ready`      → either a group picker (≥2 groups) or jump
///                      straight into the selected group's detail
struct GroupTabView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel

    @State private var showCreate = false
    @State private var showJoin = false
    /// Manual-activity sheet for the no-group state. A user without a
    /// group can still log an off-plan activity (it lands on their
    /// personal calendar) — the affordance shouldn't require joining a
    /// group first.
    @State private var showLogActivity = false
    /// Per-group settings sheet (invite, leave, rename). Hoisted to the
    /// parent so GroupDetailView doesn't add a second toolbar gear that
    /// merges with the app-settings gear below — beta feedback #39.
    @State private var showGroupSettings = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                content
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The title doubles as the group switcher (see titleSwitcher).
                ToolbarItem(placement: .principal) { titleSwitcher }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button {
                            showJoin = true
                        } label: {
                            Label("Join with code", systemImage: "person.badge.plus")
                        }
                        Button {
                            showCreate = true
                        } label: {
                            Label("Create group", systemImage: "plus.circle")
                        }
                        // Per-group settings (invite / rename / leave) for the
                        // ACTIVE group. App-level settings moved to the Profile
                        // tab, so there's no second nav-bar gear here.
                        if case .ready = groupModel.phase,
                           groupModel.selectedGroup != nil {
                            Divider()
                            Button {
                                showGroupSettings = true
                            } label: {
                                Label("Group settings…", systemImage: "person.2.gobackward")
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Theme.text)
                    }
                }
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .sheet(isPresented: $showCreate) {
                CreateGroupSheet(groupModel: groupModel)
            }
            .sheet(isPresented: $showJoin) {
                JoinGroupSheet(groupModel: groupModel)
            }
            .sheet(isPresented: $showLogActivity) {
                ManualActivitySheet { pending in
                    await groupModel.logActivity(pending)
                }
            }
            .task {
                await groupModel.load()
            }
        }
    }

    /// Nav-bar title that becomes a tap-to-switch menu when you're in 2+
    /// groups. Replaces the old "Switch group…" item buried in the "+"
    /// menu, which nobody could find. Single-group: a plain title.
    @ViewBuilder
    private var titleSwitcher: some View {
        if case .ready = groupModel.phase, groupModel.groups.count > 1 {
            Menu {
                ForEach(groupModel.groups) { g in
                    Button {
                        groupModel.selectGroup(g.id)
                    } label: {
                        if g.id == groupModel.selectedGroupID {
                            Label(g.name, systemImage: "checkmark")
                        } else {
                            Text(g.name)
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(navTitle)
                        .font(Theme.mono(15, .bold))
                        .foregroundStyle(Theme.text)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Theme.muted)
                }
            }
        } else {
            Text(navTitle)
                .font(Theme.mono(15, .bold))
                .foregroundStyle(Theme.text)
        }
    }

    private var navTitle: String {
        switch groupModel.phase {
        case .ready:
            return (groupModel.selectedGroup?.name ?? "GROUP").uppercased()
        default:
            return "GROUP"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch groupModel.phase {
        case .loading:
            ProgressView().tint(Theme.accent)
        case .error(let msg):
            errorState(msg)
        case .none:
            emptyState
        case .ready:
            if let g = groupModel.selectedGroup {
                GroupDetailView(
                    group: g,
                    groupModel: groupModel,
                    auth: auth,
                    showGroupSettings: $showGroupSettings)
            } else {
                // Defensive: phase says ready but selection is missing.
                // Should be unreachable (ensureSelection runs on load) but
                // we'd rather render the empty state than a blank screen.
                emptyState
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "person.3.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.muted)
            Text("NO GROUP YET")
                .font(Theme.mono(13, .bold)).tracking(1.5)
                .foregroundStyle(Theme.text)
            Text("Join a friends-and-family group, or start one.\nCheer each other on.")
                .font(Theme.mono(12))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Button { showJoin = true } label: {
                    Text("JOIN WITH CODE")
                        .font(Theme.mono(12, .bold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .background(Theme.accent)
                        .foregroundStyle(.black)
                        .clipShape(Capsule())
                }
                Button { showCreate = true } label: {
                    Text("CREATE GROUP")
                        .font(Theme.mono(12, .bold))
                        .padding(.horizontal, 18).padding(.vertical, 12)
                        .overlay(Capsule().stroke(Theme.muted, lineWidth: 1))
                        .foregroundStyle(Theme.text)
                }
            }
            // Logging an activity doesn't require a group — it's a personal
            // off-plan log that lands on your calendar. Offer it here so the
            // no-group state isn't a dead end for someone who just wants to
            // record a walk.
            Button { showLogActivity = true } label: {
                Label("Log an activity", systemImage: "plus.circle")
                    .font(Theme.mono(12, .bold))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.top, 4)
        }
        .padding(32)
    }

    private func errorState(_ msg: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 32))
                .foregroundStyle(Theme.danger)
            Text("Couldn't load groups")
                .font(Theme.mono(13, .bold))
                .foregroundStyle(Theme.text)
            Text(msg)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
            Button("Retry") {
                Task { await groupModel.load() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
        }
        .padding(32)
    }
}
