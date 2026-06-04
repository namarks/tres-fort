import SwiftUI

/// The "Profile" tab — one place to manage your setup: account, the Claude
/// coach connection, integrations (intervals.icu), and your groups. All
/// connection state is server-derived (GET /api/me), so it reflects creds
/// the app itself never set (env/MCP-seeded intervals, the claude.ai
/// connector). Replaces the app-settings gear that used to hide in the
/// Group tab.
struct ProfileView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel

    @State private var showJoin = false
    @State private var showCreate = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                coachSection
                integrationsSection
                groupsSection
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showJoin) { JoinGroupSheet(groupModel: groupModel) }
        .sheet(isPresented: $showCreate) { CreateGroupSheet(groupModel: groupModel) }
        .task {
            // Loads groups if the Profile tab is opened before the Group tab;
            // load() also refreshes `me`. Otherwise just refresh the snapshot.
            if groupModel.groups.isEmpty {
                await groupModel.load()
            } else {
                await groupModel.refreshMe()
            }
        }
        .refreshable { await groupModel.refreshMe() }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            if let name = groupModel.me?.display_name, !name.isEmpty {
                LabeledContent("Name", value: name)
            }
            if let email = groupModel.me?.email, !email.isEmpty {
                LabeledContent("Apple ID", value: email)
            }
            Button(role: .destructive) { auth.signOut() } label: {
                Text("Sign out")
            }
        }
    }

    // MARK: - Coach (Claude)

    @ViewBuilder
    private var coachSection: some View {
        Section {
            if groupModel.me?.claude.connected == true {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.headline)
                        if let t = groupModel.me?.claude.last_active {
                            Text("Last active \(relative(epochMs: t))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("Ask Claude to review your training, explain your numbers, or adjust your plan — in the Claude app with the Très Fort connector.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else if groupModel.me?.claude.is_owner == true {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.secondary)
                    Text("Not connected").font(.headline)
                }
                Text("Connect Claude to coach you: in the Claude app → Settings → Connectors, add “Très Fort”. Then you can ask Claude about your data and have it set up workouts.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                // Non-owner (e.g. an invited family member): they connect
                // their OWN Claude via a personal MCP connect code (M3).
                // Link to the streamlined setup flow instead of the old
                // "managed by the owner" dead-end.
                NavigationLink {
                    CoachConnectView(groupModel: groupModel)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set up your Claude coach").font(.headline)
                            Text("Connect your own Claude to get coached.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Coach (Claude)")
        }
    }

    // MARK: - Integrations

    private var integrationsSection: some View {
        Section("Integrations") {
            NavigationLink {
                IntervalsSettingsView(groupModel: groupModel)
            } label: {
                HStack {
                    Image(systemName: "bicycle").foregroundStyle(Theme.muted)
                    Text("intervals.icu")
                    Spacer()
                    if groupModel.me?.intervals.needs_reauth == true {
                        Text("Reconnect needed")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if groupModel.me?.intervals.connected == true {
                        Text(groupModel.me?.intervals.athlete_id ?? "Connected")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Groups

    @ViewBuilder
    private var groupsSection: some View {
        Section {
            if groupModel.groups.isEmpty {
                Text("You're not in a group yet.")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                ForEach(groupModel.groups) { g in
                    Button {
                        groupModel.selectGroup(g.id)
                    } label: {
                        HStack {
                            Image(systemName: g.id == groupModel.selectedGroupID
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(g.id == groupModel.selectedGroupID
                                                 ? Theme.accent : Theme.muted)
                            Text(g.name).foregroundStyle(.primary)
                            Spacer()
                            Text("\(g.member_count)")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Button { showJoin = true } label: {
                Label("Join with code", systemImage: "person.badge.plus")
            }
            Button { showCreate = true } label: {
                Label("Create group", systemImage: "plus.circle")
            }
        } header: {
            Text("Groups")
        } footer: {
            Text(groupModel.groups.count > 1
                 ? "Tap a group to make it active — it's shown in the Group tab."
                 : "Friends-and-family groups cheer each other on in the Group tab.")
        }
    }

    private func relative(epochMs: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
