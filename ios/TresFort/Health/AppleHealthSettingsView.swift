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
    /// Mirrors `me.health.sharing_in_group`. Seeded on appear; `suppressSync`
    /// guards the seeding/revert writes from re-triggering the network PATCH.
    @State private var sharing = false
    @State private var suppressSync = false
    @State private var togglingShare = false

    var body: some View {
        Form {
            statusSection
            if health.isAvailable {
                actionSection
                // Sharing stays reachable while connected OR while the server
                // still has it ON — so a user who disconnects Apple Health with
                // sharing left on can still turn off group visibility for their
                // already-pushed rows (disconnect stops syncing but doesn't flip
                // the server-side opt-in or delete those rows).
                if health.enabled || sharing {
                    sharingSection
                }
                if health.enabled {
                    disconnectSection
                }
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Seed the toggle from server truth without firing a PATCH.
            suppressSync = true
            sharing = groupModel.me?.health?.sharing_in_group ?? false
            suppressSync = false
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
                        if let t = health.lastSyncedAt {
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
            Text("Apple Health")
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
                HStack {
                    Spacer()
                    if connecting || health.isSyncing {
                        ProgressView()
                    } else {
                        Text(health.enabled ? "Sync now" : "Connect Apple Health").bold()
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

    @ViewBuilder
    private var sharingSection: some View {
        Section {
            Toggle("Show in group feed", isOn: $sharing)
                .disabled(togglingShare)
                .onChange(of: sharing) { _, newValue in
                    guard !suppressSync else { return }
                    Task { await applySharing(newValue) }
                }
        } footer: {
            Text("Off by default. When on, your Apple Health workouts appear to other members of your groups. Your lifting and intervals.icu activities are unaffected.")
        }
    }

    // MARK: - Disconnect

    @ViewBuilder
    private var disconnectSection: some View {
        Section {
            Button(role: .destructive) {
                health.disconnect()
            } label: {
                Text("Disconnect Apple Health")
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
        togglingShare = true
        defer { togglingShare = false }
        do {
            try await groupModel.setHealthSharing(newValue)
        } catch {
            // Revert the toggle without re-firing the PATCH.
            suppressSync = true
            sharing = !newValue
            suppressSync = false
        }
    }

    private func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: d, relativeTo: Date())
    }
}
