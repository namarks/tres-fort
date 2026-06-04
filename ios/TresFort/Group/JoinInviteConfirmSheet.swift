import SwiftUI

/// Shown when a Très Fort invite Universal Link (https://…/join/<code>) is
/// opened. Previews WHICH group you're about to join, then a one-tap Join
/// that reuses `GroupModel.joinGroup` — the identical redeem path as manual
/// code entry, so a deep-linked join and a typed-code join behave the same on
/// the server. Presented by `MainTabView` when `AuthModel.pendingInviteCode`
/// is set; dismissing clears that code.
struct JoinInviteConfirmSheet: View {
    @ObservedObject var groupModel: GroupModel
    let code: String
    /// Called once after a successful join so the host can jump to the Group tab.
    var onJoined: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    @State private var phase: Phase = .loading
    @State private var joining = false
    @State private var error: String?

    private enum Phase: Equatable {
        case loading
        case ready(groupName: String)
        case invalid(message: String)

        var isReady: Bool { if case .ready = self { return true } else { return false } }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background
                VStack(spacing: 18) {
                    Spacer()
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 44, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    content
                    if let error {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(Theme.danger)
                            .multilineTextAlignment(.center)
                    }
                    Spacer()
                    if case let .ready(groupName) = phase {
                        Button(action: join) {
                            HStack {
                                Spacer()
                                if joining {
                                    ProgressView().tint(.black)
                                } else {
                                    Text("Join \(groupName)").font(.headline)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 15)
                            .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                            .foregroundStyle(.black)
                        }
                        .disabled(joining)
                    }
                }
                .padding(28)
                .frame(maxWidth: 480)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase.isReady ? "Not now" : "Done") { dismiss() }
                        .disabled(joining)
                }
            }
            .task { await load() }
        }
        .preferredColorScheme(.dark)
        // Don't let a swipe-dismiss yank the sheet out from under an in-flight
        // join — otherwise the success/failure result posts to a detached view
        // and the user never sees it (and the tab silently switches).
        .interactiveDismissDisabled(joining)
    }

    @ViewBuilder private var content: some View {
        switch phase {
        case .loading:
            ProgressView().controlSize(.large).frame(maxWidth: .infinity)
        case let .ready(groupName):
            Text("Join group")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.text)
            Text(groupName)
                .font(.title.weight(.bold))
                .foregroundStyle(Theme.text)
                .multilineTextAlignment(.center)
            Text("You'll see each other's workouts and progress in a private group.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        case let .invalid(message):
            Text("Invite unavailable")
                .font(.title3.weight(.bold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func load() async {
        switch await groupModel.invitePreview(code: code) {
        case let .valid(groupName):
            phase = .ready(groupName: groupName)
        case .used:
            phase = .invalid(message: "This invite has already been used. Ask for a fresh link.")
        case .expired:
            phase = .invalid(message: "This invite has expired. Ask for a fresh link.")
        case .unknown:
            phase = .invalid(message: "We couldn't find this invite. Double-check the link.")
        case .failed:
            phase = .invalid(message: "Couldn't load this invite. Check your connection and try again.")
        }
    }

    private func join() {
        joining = true
        error = nil
        Task {
            do {
                _ = try await groupModel.joinGroup(code: code)
                joining = false
                onJoined?()
                dismiss()
            } catch let APIError.http(status, _) {
                joining = false
                error = Self.message(for: status)
            } catch {
                joining = false
                self.error = error.localizedDescription
            }
        }
    }

    private static func message(for status: Int) -> String {
        switch status {
        case 404: return "This invite is no longer valid."
        case 409: return "You're already in this group."
        case 410: return "This invite has expired or already been used."
        default: return "Couldn't join (HTTP \(status))."
        }
    }
}
