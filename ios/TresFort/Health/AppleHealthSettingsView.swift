import SwiftUI

/// Connect / disconnect Apple Health, sync on demand, and control whether your
/// workouts show in the group feed. Apple Health is on-device: the app reads
/// HKWorkouts (HealthKitSyncModel) and pushes them to the backend. "Connected"
/// is our own intent flag — Apple deliberately hides read-authorization status,
/// so we can't query whether reads were granted; we just record that the user
/// tapped Connect and ran the authorization sheet.
struct AppleHealthSettingsView: View {
    @ObservedObject var health: HealthKitSyncModel
    @ObservedObject var groupModel: GroupModel

    @State private var connecting = false
    @State private var sharing: Bool?
    @State private var loadingSharing = false
    @State private var sharingError: String?
    @State private var togglingShare = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            statusSection
            if health.isAvailable {
                actionSection
                BodyWeightAccessSection(model: health.weight)
                sharingSection
                if health.enabled || health.anchorResetPending {
                    disconnectSection
                }
            }
            Section("How your workouts are used") {
                Text("With the permissions you grant, Très Fort uploads workout records to its server: activity type, source, dates, duration, distance, calories, elevation and heart-rate summaries when available. An authorized AI app and its configured model provider can read these records. Group sharing is separate and off by default.")
                    .font(.footnote)
                PrivacyPolicyLink()
            }

        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadSharing() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await loadSharing() } }
        }
    }

    // MARK: - Status

    @ViewBuilder
    private var statusSection: some View {
        Section {
            if !health.isAvailable {
                HStack(spacing: 10) {
                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                    Text("Not available on this device").font(.headline)
                }
            } else if health.enabled {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connected").font(.headline)
                        // The first connect kicks a full historical backfill that
                        // can run for a while — say so explicitly so it doesn't
                        // read as a stuck/failed connect.
                        if health.isSyncing {
                            Text("Syncing your workouts…")
                                .font(.footnote).foregroundStyle(.secondary)
                        } else if let t = health.lastSyncedAt {
                            Text("Last synced \(relative(t))")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "heart").foregroundStyle(.secondary)
                    Text("Not connected").font(.headline)
                }
            }
            if let err = health.lastError {
                Text(err).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Workouts")
        } footer: {
            Text("Your iPhone and Apple Watch workouts — runs, rides, swims and more — read on-device and shared with your coach so it can balance your cardio against your lifting. Reads only; Très Fort never writes to Apple Health.")
        }
    }

    // MARK: - Connect / sync

    @ViewBuilder
    private var actionSection: some View {
        Section {
            Button {
                action()
            } label: {
                HStack(spacing: 8) {
                    Spacer()
                    if connecting {
                        ProgressView()
                        Text("Connecting…")
                    } else if health.enabled && health.isSyncing {
                        // Background backfill — labeled so it never reads as a
                        // hung "Connect" tap (the connect itself already
                        // succeeded; the status shows "Connected" above).
                        ProgressView()
                        Text("Syncing…")
                    } else {
                        Text(health.enabled ? "Sync workouts now" : "Connect workouts").bold()
                    }
                    Spacer()
                }
            }
            .disabled(connecting || health.isSyncing)
        } footer: {
            if !health.enabled {
                Text("You’ll be asked which data to share. Heart rate and distance make the coaching better, but duration alone is enough.")
            }
        }
    }

    // MARK: - Group-feed sharing

    private var sharingSection: some View {
        Section {
            if loadingSharing {
                ProgressView("Checking workout sharing…")
            } else if let sharing {
                // Keep an existing opt-in reachable after workout sync is
                // disconnected: stopping imports does not unshare old rows.
                if health.enabled || sharing {
                    Toggle("Show in group feed", isOn: Binding(
                        get: { self.sharing ?? false },
                        set: { value in Task { await applySharing(value) } }))
                        .disabled(togglingShare)
                        .accessibilityIdentifier("health.workoutSharing")
                } else {
                    Text("Workout sharing is off")
                        .accessibilityIdentifier("health.sharingOff")
                }
            }
            if let sharingError { Text(sharingError).font(.footnote).foregroundStyle(.orange) }
            if sharing == nil && !loadingSharing {
                Button("Retry sharing status") { Task { await loadSharing() } }
                    .accessibilityIdentifier("health.retrySharing")
            }
        } header: {
            Text("Workout sharing")
        } footer: {
            Text("Off by default. When on, your Apple Health workouts appear to other members of your groups. Your lifting and intervals.icu activities are unaffected.")
        }
    }

    private func loadSharing() async {
        guard !loadingSharing, !togglingShare else { return }
        loadingSharing = true
        sharingError = nil
        defer { loadingSharing = false }
        do {
            sharing = try await groupModel.readHealthSharing()
        } catch {
            sharing = nil
            sharingError = "Couldn’t load workout sharing. Please try again."
        }
    }

    // MARK: - Disconnect

    @ViewBuilder
    private var disconnectSection: some View {
        Section {
            Button(role: .destructive) {
                health.disconnect()
            } label: {
                Text(health.anchorResetPending ? "Retry workout sync reset" : "Disconnect workouts")
            }
        } footer: {
            Text("Stops syncing new workouts. Already-synced activities stay in your history.")
        }
    }

    // MARK: - Actions

    private func action() {
        if health.enabled {
            Task { await health.sync() }
        } else {
            connecting = true
            Task {
                await health.connect()
                connecting = false
            }
        }
    }

    private func applySharing(_ newValue: Bool) async {
        guard let previous = sharing, !togglingShare, !loadingSharing else { return }
        togglingShare = true
        sharing = newValue
        sharingError = nil
        defer { togglingShare = false }
        do {
            try await groupModel.setHealthSharing(newValue)
        } catch {
            sharing = previous
            sharingError = "Couldn’t update workout sharing. Please try again."
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
