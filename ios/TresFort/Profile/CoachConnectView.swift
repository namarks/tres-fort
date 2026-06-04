import SwiftUI
import UIKit

/// Streamlined "connect your own Claude coach" flow for a non-owner member
/// (e.g. a family member you invited). It generates an MCP *connect code* —
/// a server-stored passphrase the APP makes for the user, so they never have
/// to invent or remember one — and walks them through pasting it into Claude's
/// custom-connector setup. That code binds their Claude OAuth session to THIS
/// account at `/oauth/authorize`, so their Claude coaches their own training.
///
/// Replaces the old "managed by the group owner" dead-end in ProfileView.
struct CoachConnectView: View {
    @ObservedObject var groupModel: GroupModel

    @State private var code: String?
    @State private var generating = false
    @State private var error: String?

    /// The MCP endpoint the Claude connector points at — derived from the
    /// same base URL the app talks to, so dev and prod stay in lockstep
    /// (never hardcode the host here).
    private var connectorURL: String { Config.apiBaseURL.absoluteString + "/mcp" }

    var body: some View {
        Form {
            Section {
                Text("Très Fort coaches you through Claude. Link your own Claude account once, then just chat with it — ask for a plan, log changes, review your progress. Your workouts show up here in the app.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            Section("Step 1 · Get your connect code") {
                if let code {
                    CopyRow(label: "Connect code", value: code, mono: true)
                    Button { Task { await generate() } } label: {
                        Label(generating ? "Generating…" : "Generate a new code",
                              systemImage: "arrow.clockwise")
                    }
                    .disabled(generating)
                } else {
                    Button { Task { await generate() } } label: {
                        Label(generating ? "Generating…" : "Generate connect code",
                              systemImage: "key.fill")
                    }
                    .disabled(generating)
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                }
            }

            if code != nil {
                Section("Step 2 · Add Très Fort in Claude") {
                    instruction(1, "Open claude.ai and sign in. (Connectors need a paid Claude plan — Claude Pro.)")
                    Link(destination: URL(string: "https://claude.ai")!) {
                        Label("Open claude.ai", systemImage: "arrow.up.right.square")
                            .font(.footnote.weight(.semibold))
                    }
                    instruction(2, "Go to Settings → Connectors → Add custom connector.")
                    CopyRow(label: "Name", value: "Très Fort", mono: false)
                    CopyRow(label: "URL", value: connectorURL, mono: true)
                }

                Section("Step 3 · Paste the code") {
                    instruction(1, "When Claude asks for a connect code, paste the code from Step 1 and approve.")
                    instruction(2, "Done. Open a chat and say “What's my workout today?” or “Build me a plan.”")
                }

                Section {
                    Text("Keep this code private — it links Claude to your account. Lost it, or want to rotate it? Generate a new one anytime; it won't disconnect a Claude that's already linked.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connect your coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
    }

    @MainActor
    private func generate() async {
        generating = true
        error = nil
        defer { generating = false }
        do {
            code = try await groupModel.generateClaudeConnectCode()
        } catch let APIError.http(status, _) where status == 409 {
            // The random code collided with another user's (astronomically
            // unlikely) — a fresh tap fixes it.
            error = "That code was already taken — tap again for a new one."
        } catch {
            self.error = "Couldn't generate a code. Check your connection and try again."
        }
    }

    @ViewBuilder
    private func instruction(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(n)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
                .frame(width: 16, alignment: .leading)
            Text(text).font(.footnote)
        }
    }
}

/// A label + value row whose whole surface is a one-tap "copy to clipboard"
/// button, with a brief checkmark confirmation. Used for the connect code,
/// the connector URL, and the connector name so every paste target is one tap.
private struct CopyRow: View {
    let label: String
    let value: String
    let mono: Bool
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label).font(.caption).foregroundStyle(.secondary)
                    Text(value)
                        .font(mono ? .system(.body, design: .monospaced) : .body)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                Spacer(minLength: 12)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : Theme.accent)
            }
        }
    }
}
