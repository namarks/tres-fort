import SwiftUI

/// Available activity sources, with device-routing guidance on demand.
struct ConnectionsView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var health: HealthKitSyncModel

    private var intervalsConnected: Bool {
        groupModel.intervalsStatus?.connected == true
    }
    private var intervalsNeedsReauth: Bool {
        groupModel.intervalsStatus?.needs_reauth == true
    }

    var body: some View {
        Form {
            Section("Activity sources") {
                NavigationLink {
                    IntervalsSettingsView(groupModel: groupModel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text("intervals.icu").font(.headline)
                            if groupModel.intervalsStatusUnavailable || groupModel.intervalsStatus == nil {
                                Text("Check connection status").font(.footnote).foregroundStyle(.secondary)
                            } else if intervalsNeedsReauth {
                                Label("Reconnect needed", systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(.orange)
                            } else if intervalsConnected && groupModel.intervalsStatus?.sync_pending == true {
                                Label("Connected · Sync pending", systemImage: "arrow.clockwise")
                                    .font(.footnote).foregroundStyle(.orange)
                            } else if intervalsConnected {
                                Label("Connected", systemImage: "checkmark.circle.fill")
                                    .font(.footnote).foregroundStyle(.green)
                            } else {
                                Text("Workouts and planned rides")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("connections.intervals")
                appleHealthRow
            }

            Section {
                DisclosureGroup("Other devices") {
                    Text("Connect Garmin, Zwift, Polar or Wahoo to intervals.icu, then connect intervals.icu here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text("Strava-synced activities arrive without details. Connect your device to intervals.icu directly.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("connections.otherDevices")
            }
        }
        .navigationTitle("Connections")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Apple Health: a live connector when HealthKit is available, otherwise a
    /// disabled "not available" row (e.g. iPad). Status mirrors the local intent
    /// flag (Apple hides read-auth, so there's no server truth to read).
    @ViewBuilder
    private var appleHealthRow: some View {
        if health.isAvailable {
            NavigationLink {
                AppleHealthSettingsView(health: health, groupModel: groupModel)
            } label: {
                AppleHealthConnectionLabel(health: health, weight: health.weight)
            }
            .accessibilityIdentifier("connections.appleHealth")
        } else {
            HStack(spacing: 12) {
                Image(systemName: "heart").foregroundStyle(Theme.muted).frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Apple Health")
                    Text("Not available on this device")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .opacity(0.6)
        }
    }
}

/// Observe both permissions so changing weight updates the single source row.
private struct AppleHealthConnectionLabel: View {
    @ObservedObject var health: HealthKitSyncModel
    @ObservedObject var weight: BodyWeightModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "heart")
                .foregroundStyle(health.enabled || weight.enabled ? Theme.accent : Theme.muted)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("Apple Health").font(.headline)
                if health.enabled || weight.enabled {
                    Label(health.enabled && weight.enabled ? "Workouts and weight enabled"
                          : weight.enabled ? "Weight enabled" : "Workouts enabled",
                          systemImage: "checkmark.circle.fill")
                        .font(.footnote).foregroundStyle(.green)
                } else {
                    Text("Workouts and body weight")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}
