import SwiftUI

/// Form for connecting/disconnecting the user's intervals.icu account
/// (M1). Writes go through PATCH /api/me/integrations/intervals; the
/// "Connected" state is read from the server snapshot (GET /api/me, via
/// `groupModel.me`) OR the local post-PATCH mirror — so creds set
/// elsewhere (env/MCP-seeded) still show as connected.
struct IntervalsSettingsView: View {
    @ObservedObject var groupModel: GroupModel

    @State private var apiKey: String = ""
    @State private var athleteID: String = ""
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var oauthRunning = false
    @State private var oauthError: String?

    /// "Connected" comes from the SERVER (GET /api/me) OR the local mirror
    /// (set when you connect from this device). Server-truth is what fixes
    /// the old false "Not connected" for env/MCP-seeded creds.
    private var isConnected: Bool {
        groupModel.intervalsConnection != nil || groupModel.me?.intervals.connected == true
    }
    private var athleteID_: String? {
        groupModel.intervalsConnection?.athlete_id ?? groupModel.me?.intervals.athlete_id
    }

    var body: some View {
        Form {
            Section {
                if isConnected {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected").font(.headline)
                            if let aid = athleteID_ {
                                Text("Athlete \(aid)")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    // Only known when connected from THIS device.
                    if let conn = groupModel.intervalsConnection {
                        LabeledContent("Connected at",
                                       value: relative(epochMs: conn.connected_at))
                    }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Not connected").font(.headline)
                    }
                }
            } header: {
                Text("intervals.icu")
            } footer: {
                Text("We poll intervals.icu in the background for your planned rides and completed activities. Friends in your group see them in the feed.")
            }

            Section {
                Button {
                    connectOAuth()
                } label: {
                    HStack {
                        Spacer()
                        if oauthRunning {
                            ProgressView()
                        } else {
                            Text(isConnected ? "Reconnect with intervals.icu"
                                             : "Connect with intervals.icu")
                                .bold()
                        }
                        Spacer()
                    }
                }
                .disabled(oauthRunning || saving)
                if let oauthError {
                    Text(oauthError)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            } footer: {
                Text("One-tap: sign in to intervals.icu and approve. Or enter an API key below.")
            }

            Section {
                SecureField(isConnected ? "New API key" : "API key",
                            text: $apiKey)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                TextField("Athlete ID (e.g. i12345)", text: $athleteID)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                Button {
                    save()
                } label: {
                    HStack {
                        Spacer()
                        if saving {
                            ProgressView()
                        } else {
                            Text(isConnected ? "Reconnect" : "Connect")
                                .bold()
                        }
                        Spacer()
                    }
                }
                .disabled(apiKey.isEmpty || athleteID.isEmpty || saving)
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
                Link(destination: URL(string: "https://intervals.icu/settings")!) {
                    Label("Open intervals.icu settings", systemImage: "arrow.up.right.square")
                }
            } header: {
                Text("Credentials")
            } footer: {
                Text("Find your API key under Settings → Developer. Your Athlete ID (like i123456) is in the address bar when you open your profile.")
            }

            if isConnected {
                Section {
                    Button(role: .destructive) {
                        disconnect()
                    } label: {
                        Text("Disconnect")
                    }
                }
            }
        }
        .navigationTitle("Intervals.icu")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func connectOAuth() {
        oauthRunning = true
        oauthError = nil
        Task {
            do {
                // On success, connectIntervalsViaOAuth refreshes /api/me, so
                // `isConnected` flips via groupModel.me. A dismissed sheet
                // returns false → no-op (stay put). Errors surface below.
                _ = try await groupModel.connectIntervalsViaOAuth()
                oauthRunning = false
            } catch {
                oauthError = "Couldn't connect to intervals.icu. Try again, or use an API key below."
                oauthRunning = false
            }
        }
    }

    private func save() {
        saving = true
        errorMessage = nil
        let key = apiKey
        let id = athleteID
        Task {
            do {
                try await groupModel.setIntervalsCredentials(apiKey: key, athleteID: id)
                apiKey = ""    // never persist the key in @State
                saving = false
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }

    private func disconnect() {
        saving = true
        errorMessage = nil
        Task {
            do {
                try await groupModel.disconnectIntervals()
                athleteID = ""
                saving = false
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }

    private func relative(epochMs: Int) -> String {
        let d = Date(timeIntervalSince1970: TimeInterval(epochMs) / 1000)
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
