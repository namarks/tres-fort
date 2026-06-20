import SwiftUI

/// Multi-source connections screen (see docs/CONNECTIONS-UI-SPEC.md).
///
/// v1 scope: intervals.icu is the PRIMARY recommended connection (it aggregates
/// Garmin/Zwift/Polar/Wahoo and carries the richest data). Apple Health is now
/// a real direct connection (on-device HealthKit reader → push). Garmin / Polar
/// / Wahoo still render as disabled "Coming soon" rows — those are later phases.
/// The intervals hero pushes `IntervalsSettingsView`; Apple Health pushes
/// `AppleHealthSettingsView`.
struct ConnectionsView: View {
    @ObservedObject var groupModel: GroupModel
    @ObservedObject var health: HealthKitSyncModel

    private var intervalsConnected: Bool {
        groupModel.intervalsConnection != nil || groupModel.me?.intervals.connected == true
    }
    private var intervalsNeedsReauth: Bool {
        groupModel.me?.intervals.needs_reauth == true
    }
    private var athleteID: String? {
        groupModel.intervalsConnection?.athlete_id ?? groupModel.me?.intervals.athlete_id
    }

    var body: some View {
        Form {
            Section {
                Text("Connect where your workouts are recorded, so your coach can see your cardio and balance it against your lifting.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                NavigationLink {
                    IntervalsSettingsView(groupModel: groupModel)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "chart.line.uptrend.xyaxis")
                            .font(.title3)
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 6) {
                                Text("intervals.icu").font(.headline)
                                Text("Recommended")
                                    .font(.caption2).bold()
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Theme.accent.opacity(0.15))
                                    .foregroundStyle(Theme.accent)
                                    .clipShape(Capsule())
                            }
                            if intervalsNeedsReauth {
                                Label("Reconnect needed", systemImage: "exclamationmark.circle")
                                    .font(.footnote).foregroundStyle(.orange)
                            } else if intervalsConnected {
                                Label(athleteID.map { "Connected · \($0)" } ?? "Connected",
                                      systemImage: "checkmark.circle.fill")
                                    .font(.footnote).foregroundStyle(.green)
                            } else {
                                Text("One hub for Garmin, Zwift, Polar & Wahoo — the richest data")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text("Recommended")
            } footer: {
                if !intervalsConnected {
                    Text("New to intervals.icu? It pulls in your Garmin, Zwift, Polar or Wahoo workouts. Tap to connect — or to set up your device first.")
                }
            }

            Section {
                appleHealthRow
                comingSoonRow(name: "Garmin", icon: "applewatch",
                              detail: "If you record on a Garmin watch or bike computer")
                comingSoonRow(name: "Polar", icon: "waveform.path.ecg",
                              detail: "If you train with a Polar watch")
                comingSoonRow(name: "Wahoo", icon: "bicycle",
                              detail: "If you use a Wahoo bike computer")
            } header: {
                Text("Or connect directly")
            } footer: {
                Text("Apple Health connects your iPhone & Apple Watch directly. Garmin, Polar and Wahoo are coming soon — for now, connect those to intervals.icu above and your workouts flow through with full detail.")
            }

            Section {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Text("Using Strava? Strava-synced activities arrive without details. Connect intervals.icu or your device directly instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
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
                HStack(spacing: 12) {
                    Image(systemName: "heart")
                        .foregroundStyle(health.enabled ? Theme.accent : Theme.muted)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Apple Health")
                        if health.enabled {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.footnote).foregroundStyle(.green)
                        } else {
                            Text("Your iPhone & Apple Watch, no extra account")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
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

    @ViewBuilder
    private func comingSoonRow(name: String, icon: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(Theme.muted)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Text("Coming soon")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .opacity(0.6)
    }
}
