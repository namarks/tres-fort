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

    /// Used inside sentences and on the consent button.
    var shortName: String { self == .other ? "your AI app" : name }

    var recipient: String {
        switch self {
        case .codex: return "Codex and its configured model provider"
        case .claude: return "Claude, operated by Anthropic"
        case .other: return "Your chosen AI app and its configured model provider"
        }
    }
}

/// The data categories an authorized AI app can read, shown before any setup
/// step and on the approval screen. Keep aligned with the MCP read tools and
/// the privacy policy's AI section.
enum CoachSharing {
    static let sharedData = [
        "Training profile: goals, activities, experience, equipment, movements to avoid and lifts you reported",
        "Training plan, schedule and plan history",
        "Workout history: sets, weights, reps, durations, effort and fatigue ratings",
        "Saved workout feedback and notes",
        "Workouts imported from Apple Health or Intervals.icu, including heart-rate summaries",
        "Group activity and member names visible to you",
    ]
}

/// Public setup payloads contain only connection details, never account codes.
enum CoachSetup {
    static func serverURL(baseURL: URL) -> URL { baseURL.appendingPathComponent("mcp") }

    static func claudeInstallURL(baseURL: URL) -> URL {
        var url = URLComponents(string: "https://claude.ai/customize/connectors")!
        url.queryItems = [
            URLQueryItem(name: "modal", value: "add-custom-connector"),
            URLQueryItem(name: "connectorName", value: "Très Fort"),
            URLQueryItem(name: "connectorUrl", value: serverURL(baseURL: baseURL).absoluteString)
        ]
        return url.url!
    }

    static func codexSetupPrompt(baseURL: URL) -> String {
        """
        Help me connect Très Fort as my AI coach in Codex. Add a remote MCP server named tres-fort at \(serverURL(baseURL: baseURL).absoluteString), using OAuth. Preserve my other connections; if that name already exists, check it before changing anything. Start the OAuth sign-in and guide me through approving access in my browser. I will enter any Très Fort connect code directly on its consent page, never in this chat. After connecting, load my Très Fort coaching brief to verify access. Do not change my training plan or log anything during setup.
        """
    }
}

struct CoachConnectView: View {
    @ObservedObject var groupModel: GroupModel
    var onHandoff: () -> Void
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var selectedApp: CoachApp = .claude
    /// App Review 5.1.1(i)/5.1.2(i): setup, connection details and connect codes
    /// stay hidden until the member allows sharing with the named recipient.
    /// Choosing a different app asks again.
    @State private var consentedApp: CoachApp?
    @State private var code: String?
    @State private var generating = false
    @State private var error: String?

    private static let setupTopID = "coach.setup-top"
    private var connectorURL: String { CoachSetup.serverURL(baseURL: Config.apiBaseURL).absoluteString }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                if groupModel.me?.coach.connected == true {
                    Section {
                        Label("An AI app has access", systemImage: "checkmark.circle.fill")
                            .accessibilityIdentifier("coach.connected-status")
                        Text("You can connect Claude and Codex to the same training account.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                Section {
                    Text("Choose where you want to chat. Your coach can build a plan and adapt it as you train; your workouts stay here.")
                        .font(.footnote)
                    Picker("AI app", selection: $selectedApp) {
                        ForEach(CoachApp.allCases) { app in
                            Text(app.name).tag(app)
                        }
                    }
                    .accessibilityIdentifier("coach.app-picker")
                }
                if consentedApp == selectedApp {
                    setupSections
                } else {
                    consentSection
                }
            }
            // The consent button sits below the disclosure; bring the member back
            // to the first setup step once they allow sharing.
            .onChange(of: consentedApp) { _, app in
                guard app != nil else { return }
                DispatchQueue.main.async { proxy.scrollTo(Self.setupTopID, anchor: .top) }
            }
        }
        .navigationTitle("Connect your coach")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .preferredColorScheme(.dark)
        .task { await groupModel.refreshMe() }
    }

    @ViewBuilder
    private var consentSection: some View {
        Section("Before you connect") {
            Text("Share your training data with \(selectedApp.recipient)?")
                .font(.headline)
                .accessibilityIdentifier("coach.data-sharing")
            Text("To coach you, \(selectedApp.shortName) reads and changes your Très Fort data through a connection you approve. Nothing is sent until you allow it here and then approve the connection.")
                .font(.footnote)
            VStack(alignment: .leading, spacing: 6) {
                Text("What is shared").font(.subheadline.weight(.semibold))
                ForEach(CoachSharing.sharedData, id: \.self) { item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.secondary).accessibilityHidden(true)
                        Text(item)
                    }
                }
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("coach.shared-data")
            VStack(alignment: .leading, spacing: 6) {
                Text("Who receives it").font(.subheadline.weight(.semibold))
                Text("\(selectedApp.recipient). They process it under their own terms and privacy policy, using your account with them.")
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                Text("What it can do").font(.subheadline.weight(.semibold))
                Text("Read the information above, change your training plan and record training updates. Changes are saved to your plan history.")
            }
            .font(.footnote)
            .accessibilityElement(children: .combine)
            Text("You can stop future access anytime in Profile → Disconnect all AI apps. Information already sent stays subject to the recipient’s policies.")
                .font(.footnote).foregroundStyle(.secondary)
            providerPolicyLinks
            PrivacyPolicyLink()
            Button {
                consentedApp = selectedApp
            } label: {
                Text("Allow sharing with \(selectedApp.shortName)")
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("coach.consent-allow")
            Button("Not now", role: .cancel) { dismiss() }
                .frame(maxWidth: .infinity, minHeight: 44)
                .accessibilityIdentifier("coach.consent-decline")
        }
    }

    @ViewBuilder
    private var setupSections: some View {
        setupInstructions
        Section("Start coaching") {
            Text("Once connected, ask your AI app: “Use Très Fort to load my coaching brief.” After a plan change, return to Today and refresh.")
                .font(.footnote)
            Text("Use your own AI account. Availability and usage limits depend on the provider.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        Section {
            DisclosureGroup("Use a connect code") {
                Text("Use this if your AI app asks for a code or you cannot return to Très Fort to approve. Paste it only on the Très Fort consent page, never in a chat.")
                    .font(.footnote)
                if let code {
                    CopyRow(label: "Connect code", value: code, mono: true)
                }
                Button { Task { await generate() } } label: {
                    Label(generating ? "Generating…" : code == nil ? "Generate connect code" : "Generate a new code",
                          systemImage: code == nil ? "key.fill" : "arrow.clockwise")
                }
                .disabled(generating)
                .accessibilityIdentifier("coach.generate-code")
                if let error { Text(error).font(.footnote).foregroundStyle(Theme.danger) }
                Text("Keep this code private. A new code does not disconnect linked apps. Manage AI access in Profile to disconnect them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("Data and access") { sharingDetails }
        }
    }

    @ViewBuilder
    private var setupInstructions: some View {
        Section("Connect \(selectedApp.name)") {
            Label("You allowed sharing with \(selectedApp.recipient). Review the requested access again before approving the connection.",
                  systemImage: "checkmark.shield")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("coach.consent-given")
                .id(Self.setupTopID)
            switch selectedApp {
            case .claude:
                Button {
                    openURL(CoachSetup.claudeInstallURL(baseURL: Config.apiBaseURL)) { accepted in
                        guard accepted else { return }
                        // Free the setup presentation before the browser returns
                        // with a separate, explicit access-approval intent.
                        onHandoff()
                    }
                } label: {
                    Label("Connect with Claude", systemImage: "arrow.up.right.square")
                        .font(.headline).frame(minHeight: 44)
                }
                .accessibilityIdentifier("coach.connect-claude")
                .contextMenu {
                    Button("Copy setup link", systemImage: "link") {
                        UIPasteboard.general.url = CoachSetup.claudeInstallURL(baseURL: Config.apiBaseURL)
                    }
                }
                Text("The link fills in Très Fort’s details. Sign in to Claude, confirm the connector, then choose Open Très Fort to review access and allow the connection.")
                    .font(.footnote)
                Text("If Claude opens without the setup form, return here and press and hold Connect with Claude to copy the link, then paste it into Safari. If app approval is unavailable, use a connect code below.")
                    .font(.footnote).foregroundStyle(.secondary)
                DisclosureGroup("Manual setup") {
                    Text("On claude.ai, open Customize → Connectors → + → Add custom connector.")
                        .font(.footnote)
                    connectionDetails
                }
            case .codex:
                CopyRow(label: "Copy setup for Codex",
                        value: CoachSetup.codexSetupPrompt(baseURL: Config.apiBaseURL),
                        mono: false, hideValue: true)
                    .accessibilityIdentifier("coach.codex-setup")
                Text("Paste this into Codex and let it set up the connection. Complete the browser sign-in on the computer running Codex; use a connect code below when asked.")
                    .font(.footnote)
                Text("Codex currently needs a computer for initial setup. Once paired, ChatGPT’s Remote feature lets you use that connection from your phone while the computer stays online.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("coach.codex-mobile-limit")
                Link("Using Codex from your phone", destination: AppInformation.codexRemoteGuideURL)
                DisclosureGroup("Manual setup") {
                    Text("In the Codex desktop app, open Settings → MCP servers → Add server. Choose Streamable HTTP and enter these details. Save, restart if prompted, then select Authenticate.")
                        .font(.footnote)
                    connectionDetails
                    Link("Codex connection guide", destination: AppInformation.codexMCPGuideURL)
                    DisclosureGroup("Command-line setup") {
                        CopyRow(label: "Add server", value: "codex mcp add tres-fort --url \(connectorURL)", mono: true)
                        CopyRow(label: "Sign in", value: "codex mcp login tres-fort", mono: true)
                    }
                }
            case .other:
                Text("In your AI app, add a remote MCP server with OAuth sign-in using these details. Models need a compatible host app to connect.")
                    .font(.footnote)
                connectionDetails
                Text("Approve in Très Fort when offered, or use a connect code below. Apps that only accept API keys or static tokens are not supported by this setup.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var sharingDetails: some View {
        Text("\(selectedApp.recipient) can read your training plan, workout history, saved feedback and available group information, including workouts imported from Apple Health or Intervals.icu. The connection also allows changes to your plan and training records.")
            .font(.footnote)
        Text("Disconnect AI apps in Profile to stop future access. Information already retrieved stays subject to the app and model provider’s policies and account settings. The Apple Health group-sharing switch does not limit your own coach’s access.")
            .font(.footnote).foregroundStyle(.secondary)
        PrivacyPolicyLink()
        providerPolicyLinks
    }

    @ViewBuilder
    private var providerPolicyLinks: some View {
        switch selectedApp {
        case .codex:
            Link("OpenAI privacy policy", destination: AppInformation.openAIPrivacyURL)
            Text("If you configure another model provider, review that provider’s privacy policy too.")
                .font(.footnote).foregroundStyle(.secondary)
        case .claude:
            Link("Anthropic privacy policy", destination: AppInformation.anthropicPrivacyURL)
        case .other:
            Text("Review your chosen app and model provider’s privacy policies before connecting.")
                .font(.footnote).foregroundStyle(.secondary)
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
}

private struct CopyRow: View {
    let label: String
    let value: String
    let mono: Bool
    var hideValue = false
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = value
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(copied && hideValue ? "Copied setup for Codex" : label)
                        .font(hideValue ? .headline : .caption)
                        .foregroundStyle(hideValue ? .primary : .secondary)
                    if !hideValue { Text(value)
                        .font(mono ? .system(.footnote, design: .monospaced) : .body)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 12)
                Image(systemName: copied ? "checkmark.circle.fill" : "doc.on.doc")
                    .foregroundStyle(copied ? .green : Theme.accent)
            }
        }
    }
}
