import SwiftUI
import UniformTypeIdentifiers

private struct AccountExportDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

/// The "Profile" tab — one place to manage your setup: account, the Claude
/// coach connection, integrations (intervals.icu), and your groups. All
/// connection state is server-derived (GET /api/me), so it reflects creds
/// the app itself never set (env/MCP-seeded intervals, the claude.ai
/// connector). Replaces the app-settings gear that used to hide in the
/// Group tab.
struct ProfileView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var auth: AuthModel
    @ObservedObject var health: HealthKitSyncModel
    var sync: SyncModel? = nil

    @State private var showJoin = false
    @State private var showCreate = false
    @State private var showNameEditor = false
    @State private var accountExportDocument: AccountExportDocument?
    @State private var accountExportFilename = "tres-fort-account-export.json"
    @State private var showAccountExporter = false
    @State private var isExportingAccount = false
    @State private var showExportError = false
    @State private var exportErrorMessage = ""
    @State private var showDeleteConfirmation = false
    @State private var isDeletingAccount = false
    @State private var showDeletionError = false
    @State private var deletionErrorMessage = ""
    @State private var showCoachDisconnectConfirmation = false
    @State private var isDisconnectingCoach = false
    @State private var coachDisconnectMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                accountSection
                coachSection
                integrationsSection
                groupsSection
                Section {
                    NavigationLink("Group safety") { GroupSafetyView(model: groupModel) }
                }
                Section("About Très Fort") {
                    PrivacyPolicyLink()
                    Link("Contact support", destination: AppInformation.supportURL)
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showJoin) { JoinGroupSheet(groupModel: groupModel) }
        .sheet(isPresented: $showCreate) { CreateGroupSheet(groupModel: groupModel) }
        .sheet(isPresented: $showNameEditor) {
            EditDisplayNameSheet(
                initialName: groupModel.me?.display_name ?? "",
                onSave: { try await groupModel.updateDisplayName($0) })
        }
        .confirmationDialog(
            "Permanently delete your account?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Account", role: .destructive) {
                Task { await deleteConfirmedAccount() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes your training plan, workout history, connected-service credentials, Claude tokens, and group memberships. Groups with other members will continue under another member. This cannot be undone.")
        }
        .alert("Account wasn’t deleted", isPresented: $showDeletionError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(deletionErrorMessage)
        }
        .alert("Account data wasn’t downloaded", isPresented: $showExportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportErrorMessage)
        }
        .confirmationDialog(
            "Disconnect Claude?",
            isPresented: $showCoachDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect Claude", role: .destructive) {
                Task { await disconnectCoach() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This revokes Claude’s access to your training. Your workouts and plan stay in Très Fort.")
        }
        .alert(
            "Coach connection",
            isPresented: Binding(
                get: { coachDisconnectMessage != nil },
                set: { if !$0 { coachDisconnectMessage = nil } })
        ) {
            Button("OK", role: .cancel) { coachDisconnectMessage = nil }
        } message: {
            Text(coachDisconnectMessage ?? "")
        }
        .fileExporter(
            isPresented: $showAccountExporter,
            document: accountExportDocument,
            contentType: .json,
            defaultFilename: accountExportFilename
        ) { result in
            if case let .failure(error) = result {
                exportErrorMessage = error.localizedDescription
                showExportError = true
            }
            accountExportDocument = nil
        }
        .task {
            // Loads groups if the Profile tab is opened before the Group tab;
            // load() also refreshes `me`. Otherwise just refresh the snapshot.
            if groupModel.groups.isEmpty {
                await groupModel.load()
            } else {
                await groupModel.refreshMe()
            }
        }
        .refreshable { await groupModel.load() }
    }

    // MARK: - Account

    private var accountSection: some View {
        Section("Account") {
            HStack {
                Text("Name")
                Spacer()
                Text(groupModel.me?.display_name.flatMap { $0.isEmpty ? nil : $0 }
                     ?? "Not set")
                    .foregroundStyle(.secondary)
                Button("Edit") { showNameEditor = true }
                    .font(.footnote)
            }
            if let email = groupModel.me?.email, !email.isEmpty {
                LabeledContent("Apple ID", value: email)
            }
            Button {
                Task { await downloadAccountData() }
            } label: {
                if isExportingAccount {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Preparing account data…")
                    }
                } else {
                    Label("Download account data", systemImage: "square.and.arrow.down")
                }
            }
            .disabled(isExportingAccount || isDeletingAccount || auth.accountDeletionPending)
            Text("Saves a JSON file containing your profile and training data. It excludes credentials, access tokens, invite codes, and other members’ private data.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button(role: .destructive) { auth.signOut() } label: {
                Text("Sign out")
            }
            .disabled(isDeletingAccount || auth.accountDeletionPending)
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                if isDeletingAccount {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Deleting account…")
                    }
                } else {
                    Text(auth.accountDeletionPending
                         ? "Retry account deletion"
                         : "Delete account")
                }
            }
            .disabled(isDeletingAccount)
        }
    }

    private func downloadAccountData() async {
        guard !isExportingAccount else { return }
        isExportingAccount = true
        defer { isExportingAccount = false }
        do {
            let file = try await auth.downloadAccountExport()
            accountExportDocument = AccountExportDocument(data: file.data)
            accountExportFilename = file.filename
            showAccountExporter = true
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func deleteConfirmedAccount() async {
        guard !isDeletingAccount else { return }
        isDeletingAccount = true
        defer { isDeletingAccount = false }
        do {
            try await auth.deleteAccount()
        } catch {
            deletionErrorMessage = error.localizedDescription
            showDeletionError = true
        }
    }

    // MARK: - Coach (Claude)

    @ViewBuilder
    private var coachSection: some View {
        Section {
            if let sync {
                NavigationLink {
                    CoachingContextView(sync: sync)
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Training overview")
                        Text("Recorded training and plan settings your coach can read.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .accessibilityIdentifier("profile.trainingOverview")
            }
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
                Button("Disconnect Claude", role: .destructive) {
                    showCoachDisconnectConfirmation = true
                }
                .disabled(isDisconnectingCoach)
            } else {
                NavigationLink {
                    CoachConnectView(groupModel: groupModel)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "brain.head.profile").foregroundStyle(Theme.accent)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Set up your Claude coach").font(.headline)
                            Text("Your coach works with your own training plan, whether you train independently or in a group.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        } header: {
            Text("Coach (Claude)")
        }
    }

    private func disconnectCoach() async {
        guard !isDisconnectingCoach else { return }
        isDisconnectingCoach = true
        defer { isDisconnectingCoach = false }
        do {
            let refreshed = try await groupModel.disconnectClaude()
            if !refreshed {
                coachDisconnectMessage = "Claude was disconnected. The latest profile status couldn’t be refreshed; pull to refresh when you’re online."
            }
        } catch {
            coachDisconnectMessage = "Claude wasn’t disconnected: \(error.localizedDescription)"
        }
    }

    // MARK: - Integrations

    private var integrationsSection: some View {
        Section("Integrations") {
            NavigationLink {
                ConnectionsView(groupModel: groupModel, health: health)
            } label: {
                HStack {
                    Image(systemName: "link").foregroundStyle(Theme.muted)
                    Text("Connections")
                    Spacer()
                    if groupModel.intervalsStatusUnavailable || groupModel.intervalsStatus == nil {
                        Text("Check status").font(.footnote).foregroundStyle(.secondary)
                    } else if groupModel.intervalsStatus?.needs_reauth == true {
                        Text("Reconnect needed")
                            .font(.footnote).foregroundStyle(.orange)
                    } else if groupModel.intervalsStatus?.connected == true {
                        Text(groupModel.intervalsStatus?.athlete_id ?? "Connected")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        Text("Not connected")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityIdentifier("profile.connections")
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

private struct EditDisplayNameSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var displayName: String
    @State private var isSaving = false
    @State private var errorMessage: String?
    let onSave: (String) async throws -> Void

    init(
        initialName: String,
        onSave: @escaping (String) async throws -> Void
    ) {
        _displayName = State(initialValue: initialName)
        self.onSave = onSave
    }

    private var trimmedName: String {
        displayName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Display name", text: $displayName)
                    .textContentType(.name)
                if let errorMessage {
                    Text(errorMessage)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("Edit Name")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(
                        isSaving || trimmedName.isEmpty || trimmedName.utf16.count > 80)
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        errorMessage = nil
        do {
            try await onSave(trimmedName)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
            isSaving = false
        }
    }
}
