import SwiftUI

/// Form for connecting/disconnecting the user's intervals.icu account
/// (M1). PATCH /api/me/integrations/intervals is the only endpoint —
/// there's no GET, so iOS shows "Connected" purely from the local mirror
/// (athlete_id + last successful PATCH timestamp).
struct IntervalsSettingsView: View {
    @ObservedObject var groupModel: GroupModel

    @State private var apiKey: String = ""
    @State private var athleteID: String = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section {
                if let conn = groupModel.intervalsConnection {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Connected").font(.headline)
                            Text("Athlete \(conn.athlete_id)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    LabeledContent("Connected at",
                                   value: relative(epochMs: conn.connected_at))
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
                SecureField(groupModel.intervalsConnection == nil ? "API key" : "New API key",
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
                            Text(groupModel.intervalsConnection == nil ? "Connect" : "Reconnect")
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
            } header: {
                Text("Credentials")
            } footer: {
                Text("Generate an API key at intervals.icu → Settings → Developer. Your athlete ID is in the URL when you visit your athlete page.")
            }

            if groupModel.intervalsConnection != nil {
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
