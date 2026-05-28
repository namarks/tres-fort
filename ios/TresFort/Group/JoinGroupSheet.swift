import SwiftUI

/// Paste an invite code; tap Join. v1 = MANUAL CODE ENTRY ONLY (per M5 Q2
/// decision — Universal Link / custom scheme is M6 polish).
struct JoinGroupSheet: View {
    @ObservedObject var groupModel: GroupModel
    @Environment(\.dismiss) private var dismiss

    @State private var code: String = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("ABC123", text: $code)
                        .textInputAutocapitalization(.characters)
                        .disableAutocorrection(true)
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: code) { _, new in
                            // Codes are uppercase 6-char base-32 alphabet
                            // (no I/L/O/0/1). Normalize on the fly so a
                            // pasted lowercase code still works.
                            let cleaned = new.uppercased()
                                .filter { "ABCDEFGHJKMNPQRSTUVWXYZ23456789".contains($0) }
                                .prefix(6)
                            if String(cleaned) != new {
                                code = String(cleaned)
                            }
                        }
                } header: {
                    Text("Invite code")
                } footer: {
                    Text("Got a code from a friend or family member? Paste it here.")
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("Join group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Join") { join() }
                        .disabled(code.count != 6 || saving)
                }
            }
        }
    }

    private func join() {
        saving = true
        errorMessage = nil
        let c = code
        Task {
            do {
                _ = try await groupModel.joinGroup(code: c)
                saving = false
                dismiss()
            } catch let APIError.http(code, _) {
                errorMessage = errorMessageFor(code)
                saving = false
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }

    private func errorMessageFor(_ status: Int) -> String {
        switch status {
        case 404: return "Invalid code — check the characters and try again."
        case 409: return "You're already in this group."
        case 410: return "This invite has expired or already been used."
        default:  return "Couldn't join (HTTP \(status))."
        }
    }
}
