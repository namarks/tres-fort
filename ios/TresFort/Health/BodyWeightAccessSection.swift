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
            } else if model.failure != nil {
                BodyWeightRecoveryView(model: model)
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

/// The same recovery is available from the measurement and connection screens.
struct BodyWeightRecoveryView: View {
    @ObservedObject var model: BodyWeightModel

    var body: some View {
        if let failure = model.failure {
            VStack(alignment: .leading, spacing: 6) {
                Text(failure.title)
                    .font(.headline)
                    .accessibilityIdentifier("weight.error.title")
                Text(failure.message)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("weight.error.message")
            }
            if failure.recovery != .none {
                Button {
                    Task { await model.recover() }
                } label: {
                    Text(failure.recovery == .reconnect ? "Reconnect Apple Health" : "Try again")
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .disabled(model.isBusy)
                .accessibilityIdentifier("weight.recover")
            }
            if failure.recovery == .reconnect {
                DisclosureGroup("Check weight permissions") {
                    Text("In the Health app, open Summary and tap your profile. Under Privacy, choose Apps → Très Fort and turn on Weight. Then return here and reconnect.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .accessibilityIdentifier("weight.permissionHelp")
            }
        }
    }
}
