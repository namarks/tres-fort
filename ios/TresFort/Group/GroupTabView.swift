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
    @State private var showAppSettings = false
    @State private var showGroupPicker = false
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
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        if groupModel.groups.count > 1 {
                            Button("Switch group…") { showGroupPicker = true }
                            Divider()
                        }
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
                        // Per-group settings live here (rather than as a
                        // second toolbar gear) so we don't render two
                        // identical gear icons next to each other in the
                        // nav bar — beta feedback #39.
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
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showAppSettings = true
                    } label: {
                        Image(systemName: "gearshape")
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
            .sheet(isPresented: $showAppSettings) {
                AppSettingsView(groupModel: groupModel, auth: auth)
            }
            .confirmationDialog(
                "Switch group",
                isPresented: $showGroupPicker,
                titleVisibility: .visible
            ) {
                ForEach(groupModel.groups) { g in
                    Button(g.name) {
                        groupModel.selectedGroupID = g.id
                        Task { await groupModel.refreshGroup(groupID: g.id) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
            .task {
                await groupModel.load()
            }
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

/// Umbrella "Settings" surface for the Group tab gear button. v1 has
/// intervals.icu + sign out; future home for notifications, etc.
struct AppSettingsView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Integrations") {
                    NavigationLink {
                        IntervalsSettingsView(groupModel: groupModel)
                    } label: {
                        HStack {
                            Image(systemName: "bicycle")
                                .foregroundStyle(Theme.muted)
                            Text("Intervals.icu")
                            Spacer()
                            if let conn = groupModel.intervalsConnection {
                                Text(conn.athlete_id)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Not connected")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Section {
                    Button(role: .destructive) {
                        auth.signOut()
                        dismiss()
                    } label: {
                        Text("Sign out")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
