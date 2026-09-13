import SwiftUI
import UIKit

/// Setup choices describe AI apps, not models. A model needs a host that can
/// connect to our remote MCP server and complete the per-account OAuth flow.
enum CoachApp: String, CaseIterable, Identifiable {
    case codex, claude, other
    var id: String { rawValue }

    var name: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .other: return "Other compatible app"
        }
    }

    var recipient: String {
        switch self {
        case .codex: return "Codex and its configured model provider"
        case .claude: return "Claude, operated by Anthropic"
        case .other: return "Your chosen AI app and its configured model provider"
        }
    }
}

/// Every member connects their own account. The app-generated code is used
/// only on the Très Fort consent page, never as a model API key or bearer token.
struct CoachConnectView: View {
    @ObservedObject var groupModel: GroupModel
    @State private var selectedApp: CoachApp = .codex
    @State private var code: String?
    @State private var generating = false
    @State private var error: String?

    private var connectorURL: String { Config.apiBaseURL.absoluteString + "/mcp" }

    var body: some View {
        Form {
            if groupModel.me?.coach.connected == true {
                Section {
                    Label("Your coach is connected", systemImage: "checkmark.circle.fill")
                    Text("You can connect another AI app to the same training account. Each app reads your current plan and history from Très Fort.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                Text("Bring your own AI coach. Chat in your chosen AI app to build a plan, review progress, or make changes, then follow your workouts here.")
                    .font(.footnote)
                Text("Use your own AI account or subscription. Très Fort does not include AI usage; availability and limits depend on the app you choose.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Choose your AI app") {
                Picker("AI app", selection: $selectedApp) {
                    ForEach(CoachApp.allCases) { app in
                        Text(app.name).tag(app)
                    }
                }
                .accessibilityIdentifier("coach.app-picker")
                if selectedApp == .other {
                    Text("Choose an app that supports remote MCP connections with OAuth. Models such as GLM or Muse need a compatible app to connect; model access alone is not enough.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("What you share") {
                Text("\(selectedApp.recipient) can read your training plan, workout history, saved feedback and available group information, including workouts imported from Apple Health or Intervals.icu. The connection also allows changes to your plan and training records.")
                    .font(.footnote)
                    .accessibilityIdentifier("coach.data-sharing")
                Text("Approve access on the Très Fort consent page. Disconnect all AI apps in Profile to stop future access through these connections. Information already retrieved stays subject to the app and model provider’s policies and account settings. The Apple Health group-sharing switch does not limit your own coach’s access.")
                    .font(.footnote).foregroundStyle(.secondary)
                PrivacyPolicyLink()
                switch selectedApp {
                case .codex:
                    Link("OpenAI privacy policy", destination: AppInformation.openAIPrivacyURL)
                    Text("If you configure another model provider in your AI app, review that provider’s privacy policy too.")
                        .font(.footnote).foregroundStyle(.secondary)
                case .claude:
                    Link("Anthropic privacy policy", destination: AppInformation.anthropicPrivacyURL)
                case .other:
                    Text("Review your chosen app and model provider’s privacy policies before connecting.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section("Step 1 · Get your connect code") {
                if let code {
                    CopyRow(label: "Connect code", value: code, mono: true)
                }
                Button { Task { await generate() } } label: {
                    Label(generating ? "Generating…" : code == nil ? "Generate connect code" : "Generate a new code",
                          systemImage: code == nil ? "key.fill" : "arrow.clockwise")
                }
                .disabled(generating)
                .accessibilityIdentifier("coach.generate-code")
                if let error {
                    Text(error).font(.footnote).foregroundStyle(Theme.danger)
                }
            }
            if code != nil {
                setupInstructions
                Section("Step 3 · Approve and start coaching") {
                    instruction(1, "On the Très Fort consent page, paste your connect code and approve access. Keep the code out of chat messages.")
                    instruction(2, "In your AI app, ask: “Use Très Fort to load my coaching brief and tell me about my training.”")
                    instruction(3, "After your coach changes your plan, return to Today and refresh. You can also edit your workouts here anytime.")
                }
                Section {
                    Text("Keep this code private. Generating a new code does not disconnect apps already linked. Use Disconnect all AI apps in Profile to revoke those connections.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Connect your coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await groupModel.refreshMe() }
    }

    @ViewBuilder
    private var setupInstructions: some View {
        Section("Step 2 · Connect your AI app") {
            switch selectedApp {
            case .codex:
                instruction(1, "On your computer, open the desktop app you use for Codex. In Settings → Plugins, choose Add → Add MCP server. Some versions call this Settings → MCP servers → Add server.")
                instruction(2, "Choose Streamable HTTP and enter these connection details. No terminal commands are needed.")
                connectionDetails
                instruction(3, "Save the server, then choose Authenticate to sign in. If prompted, restart the server. Your browser opens the Très Fort consent page.")
                Text("This setup currently needs the desktop app. Adding this connection does not automatically add it to ChatGPT on the web or iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
                Link("Codex connection guide", destination: AppInformation.codexMCPGuideURL)
                DisclosureGroup("Advanced: command-line setup") {
                    CopyRow(label: "Add server", value: "codex mcp add tres-fort --url \(connectorURL)", mono: true)
                    CopyRow(label: "Sign in", value: "codex mcp login tres-fort", mono: true)
                }
                .accessibilityIdentifier("coach.advanced-setup")
            case .claude:
                instruction(1, "Open claude.ai and sign in to an account that supports custom connectors.")
                Link("Open claude.ai", destination: URL(string: "https://claude.ai")!)
                instruction(2, "Go to Settings → Connectors → Add custom connector, then connect using these details.")
                connectionDetails
            case .other:
                instruction(1, "In your AI app’s connection settings, add a remote MCP server using these details.")
                connectionDetails
                instruction(2, "Choose OAuth sign-in and follow the browser flow. If the app only accepts API keys or static tokens, this setup is not supported.")
            }
        }
    }

    @ViewBuilder
    private var connectionDetails: some View {
        CopyRow(label: "Name", value: selectedApp == .codex ? "tres-fort" : "Très Fort", mono: false)
        CopyRow(label: "URL", value: connectorURL, mono: true)
    }

    @MainActor
    private func generate() async {
        generating = true
        error = nil
        defer { generating = false }
        do {
            code = try await groupModel.generateCoachConnectCode()
        } catch is CancellationError {
            code = nil
        } catch let APIError.http(status, _) where status == 409 {
            error = "That code was already taken — tap again for a new one."
        } catch {
            self.error = "Couldn’t generate a code. Check your connection and try again."
        }
    }

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
                        .font(mono ? .system(.footnote, design: .monospaced) : .body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : Theme.accent)
            }
        }
    }
}
