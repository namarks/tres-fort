import SwiftUI

/// Server connection status and recoverable recent-activity reconciliation.
struct IntervalsSettingsView: View {
    @ObservedObject var groupModel: GroupModel
    @State private var apiKey = ""
    @State private var athleteID = ""
    @State private var errorMessage: String?

    private var status: MeProfile.IntervalsStatus? { groupModel.intervalsStatus }
    private var connected: Bool { status?.connected == true }
    private var needsReauth: Bool { status?.needs_reauth == true }
    private var unavailable: Bool { groupModel.intervalsStatusUnavailable || status == nil }
    private var retry: Bool { status?.sync_pending == true || groupModel.intervalsImportStatus == .retry }

    private var title: String {
        if groupModel.intervalsBusy { return "Updating connection…" }
        if unavailable { return "Check connection status" }
        if needsReauth { return "Reconnect needed" }
        if connected { return retry ? "Connected · Sync pending" : "Connected" }
        return "Not connected"
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    if groupModel.intervalsBusy { ProgressView() }
                    else {
                        Image(systemName: connected && !retry && !unavailable
                              ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath")
                            .foregroundStyle(connected && !retry && !unavailable ? .green : .secondary)
                    }
                    Text(title).font(.headline).accessibilityIdentifier("intervals.status")
                }
                if groupModel.intervalsBusy {
                    Text("Connecting and importing your recent activities…").font(.footnote)
                } else if unavailable {
                    Text("Refresh to check the latest connection and import status.").font(.footnote)
                    Button("Refresh status") { Task { await groupModel.refreshMe() } }
                        .accessibilityIdentifier("intervals.refresh")
                } else if needsReauth {
                    Text("Intervals.icu needs you to reconnect before new activities can sync.").font(.footnote)
                } else if connected {
                    if retry {
                        Text("Your connection is saved. Recent activities haven’t finished importing. You can retry without entering your credentials again.")
                            .font(.footnote)
                    } else if let lastSync = status?.last_synced_at {
                        LabeledContent("Last synced", value: RelativeTimeFormat.short(epochMs: lastSync))
                    }
                    Button(retry ? "Retry sync" : "Sync recent activities") {
                        errorMessage = nil
                        Task { await groupModel.retryIntervalsSync() }
                    }
                    .accessibilityIdentifier("intervals.retry")
                }
                if let aid = status?.athlete_id, !unavailable {
                    Text("Athlete \(aid)").font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("intervals.icu")
            } footer: {
                Text("Connecting imports your last 90 days of activity. Background updates keep planned rides and completed activities current. Disconnecting or reconnecting keeps your imported history.")
            }

            Section {
                Button(connected || needsReauth ? "Reconnect with intervals.icu" : "Connect with intervals.icu") {
                    errorMessage = nil
                    Task {
                        do { _ = try await groupModel.connectIntervalsViaOAuth() }
                        catch { errorMessage = "Couldn’t connect to intervals.icu. Try again, or use an API key below." }
                    }
                }
                .accessibilityIdentifier("intervals.oauth")
            } footer: {
                Text("Sign in to intervals.icu and approve, or enter an API key below.")
            }
            .disabled(groupModel.intervalsBusy)

            Section("API key") {
                SecureField("API key", text: $apiKey)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                    .accessibilityIdentifier("intervals.apiKey")
                TextField("Athlete ID (optional)", text: $athleteID)
                    .textInputAutocapitalization(.never).disableAutocorrection(true)
                Button(connected || needsReauth ? "Reconnect" : "Connect") {
                    errorMessage = nil
                    let key = apiKey, athlete = athleteID
                    Task {
                        do {
                            try await groupModel.setIntervalsCredentials(apiKey: key, athleteID: athlete)
                            apiKey = ""
                        } catch { errorMessage = "Couldn’t save the connection. Check your connection and try again." }
                    }
                }
                .disabled(apiKey.isEmpty)
                .accessibilityIdentifier("intervals.connect")
                Link("Open intervals.icu settings", destination: URL(string: "https://intervals.icu/settings")!)
            }
            .disabled(groupModel.intervalsBusy)

            if let errorMessage {
                Section { Text(errorMessage).font(.footnote).foregroundStyle(.red) }
            }
            if connected || needsReauth {
                Section {
                    Button("Disconnect", role: .destructive) {
                        errorMessage = nil
                        Task {
                            do { try await groupModel.disconnectIntervals(); athleteID = "" }
                            catch { errorMessage = "Couldn’t disconnect. Check your connection and try again." }
                        }
                    }
                    .disabled(groupModel.intervalsBusy)
                    .accessibilityIdentifier("intervals.disconnect")
                }
            }
        }
        .navigationTitle("Intervals.icu")
        .navigationBarTitleDisplayMode(.inline)
        .task { await groupModel.refreshMe() }
    }
}
