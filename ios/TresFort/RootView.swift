import AuthenticationServices
import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AuthModel

    var body: some View {
        Group {
            switch model.phase {
            case .signedIn:
                MainTabView(auth: model)
            default:
                ZStack {
                    Color.black.ignoresSafeArea()
                    VStack(spacing: 28) {
                        Text("TRÈS FORT")
                            .font(Theme.display(40)).tracking(2)
                            .foregroundStyle(.white)
                        if case let .working(msg) = model.phase {
                            ProgressView(msg).tint(.white).foregroundStyle(.white)
                        } else {
                            signedOut
                        }
                    }
                    .padding(32)
                }
                .preferredColorScheme(.dark)
            }
        }
    }

    private var signedOut: some View {
        SignedOutView(model: model)
    }
}

/// Open sign-in with optional invite code. Anyone can sign in with
/// Apple — supplying an invite code is a shortcut that auto-joins the
/// caller to the inviter's group atomically with account creation.
/// Without a code, the user signs in to an empty Group tab and can
/// create / join groups later from there.
private struct SignedOutView: View {
    @ObservedObject var model: AuthModel
    @State private var showInviteField = false
    @State private var inviteCode: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Your coach owns the plan.\nSign in to sync.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if showInviteField {
                VStack(spacing: 6) {
                    TextField("INVITE CODE", text: $inviteCode)
                        .font(.system(.body, design: .monospaced).weight(.bold))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .padding(.vertical, 10)
                        .background(Color.white.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .onChange(of: inviteCode) { _, new in
                            // 6-char base-32 alphabet (no I/L/O/0/1) per
                            // the backend invite generator. Normalize on
                            // the fly so a pasted lowercase code works.
                            let cleaned = new.uppercased()
                                .filter { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
                                .prefix(6)
                            if String(cleaned) != new {
                                inviteCode = String(cleaned)
                            }
                        }
                    Text("6 letters/numbers, no I L O 0 1")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            SignInWithAppleButton(.signIn,
                                  onRequest: { req in
                                      req.requestedScopes = [.fullName, .email]
                                      // Stash the code so handleAppleResult can
                                      // pick it up out-of-band (the callback
                                      // doesn't take user data).
                                      model.pendingInviteCode =
                                          inviteCode.isEmpty ? nil : inviteCode
                                  },
                                  onCompletion: model.handleAppleResult)
                .signInWithAppleButtonStyle(.white)
                .frame(height: 50)
                .cornerRadius(10)

            Button {
                withAnimation { showInviteField.toggle() }
            } label: {
                Text(showInviteField ? "Sign in without code" : "Have an invite code?")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .underline()
            }

            if case let .error(msg) = model.phase {
                Text(msg)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
    }
}
