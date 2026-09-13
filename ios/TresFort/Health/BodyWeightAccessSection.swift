import SwiftUI

/// Weight is an optional data permission within the existing Health source.
struct BodyWeightAccessSection: View {
    @ObservedObject var model: BodyWeightModel

    var body: some View {
        Section {
            Toggle("Read weight", isOn: Binding(
                get: { model.enabled },
                set: { enabled in
                    if enabled { Task { await model.connect() } }
                    else { model.disconnect() }
                }))
                .disabled((model.isBusy && !model.enabled) || !model.isAvailable || model.requiresPersonalSignIn)
                .accessibilityIdentifier("health.readWeight")
            if model.requiresPersonalSignIn {
                Text("Sign in with your personal account to use Apple Health weight.")
                    .font(.footnote)
            } else if model.isBusy {
                ProgressView(model.isConnecting ? "Requesting access…" : "Reading weight…")
            } else if let error = model.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.orange)
            } else if model.enabled {
                Text("View measurements in Progress → Weight.").font(.footnote)
            }
        } header: {
            Text("Weight")
        } footer: {
            Text("Optional. Read measurements shared with Apple Health by your scale or entered in Health. Weight stays on this iPhone and is visible only to you in Très Fort. Turning this off clears the view; your Health measurements remain. You can change read permissions in the Health app.")
        }
    }
}
