import SwiftUI

/// Shared by Today and direct manual setup, including a sheet opened before
/// the account's first network read finishes.
struct PlanLoadRecoveryView: View {
    @ObservedObject var sync: SyncModel

    var body: some View {
        VStack(spacing: 14) {
            if sync.isLoading || sync.loadError == nil {
                ProgressView().tint(Theme.accent)
                Text("Checking your plan…")
                    .font(.headline).foregroundStyle(Theme.text)
            } else {
                Text("Couldn’t load your plan")
                    .font(.title2.weight(.bold)).foregroundStyle(Theme.text)
                Text(sync.loadError ?? "")
                    .font(.callout).foregroundStyle(Theme.text)
                    .accessibilityIdentifier("today.load-error")
                    .multilineTextAlignment(.center)
                Text("Your plan may already be saved. Try again when you're connected to continue with your existing training.")
                    .font(.footnote).foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                Button { Task { await sync.load() } } label: {
                    Text("Try again").frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
                }
            }
        }
        .padding(24)
    }
}
