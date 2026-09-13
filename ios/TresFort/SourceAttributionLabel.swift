import SwiftUI

/// Always visible beside sourced content; wraps rather than truncating a model.
struct SourceAttributionLabel: View {
    static let summary = "Includes Garmin device-sourced data"
    let text: String?

    var body: some View {
        if let text, !text.isEmpty {
            Text(verbatim: text)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("activity.sourceAttribution")
        }
    }
}
