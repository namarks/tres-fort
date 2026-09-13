import SwiftUI

enum AppInformation {
    static let privacyURL = URL(string: "https://tresfort.app/privacy")!
    static let supportURL = URL(string: "mailto:nick@tresfort.app")!
    static let openAIPrivacyURL = URL(string: "https://openai.com/policies/privacy-policy/")!
    static let codexMCPGuideURL = URL(string: "https://developers.openai.com/codex/mcp")!
    static let anthropicPrivacyURL = URL(string: "https://www.anthropic.com/legal/privacy")!
}

struct PrivacyPolicyLink: View {
    var body: some View {
        Link(destination: AppInformation.privacyURL) {
            Text("Privacy policy").frame(minHeight: 44)
        }
        .accessibilityIdentifier("app.privacy-policy")
    }
}
