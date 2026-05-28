import SwiftUI

/// Create a new group. v1 = single text field (per M5 Q1 decision: ship a
/// thin Create so the FIRST user has somewhere to start).
struct CreateGroupSheet: View {
    @ObservedObject var groupModel: GroupModel
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var saving = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("e.g. Marks Family", text: $name)
                        .textInputAutocapitalization(.words)
                }
                if let errorMessage {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }
            .navigationTitle("Create group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }
                        .disabled(!canCreate)
                }
            }
        }
    }

    private var canCreate: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !saving
    }

    private func create() {
        saving = true
        errorMessage = nil
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                _ = try await groupModel.createGroup(name: trimmed)
                saving = false
                dismiss()
            } catch let APIError.http(_, body) {
                errorMessage = "Couldn't create: \(body)"
                saving = false
            } catch {
                errorMessage = error.localizedDescription
                saving = false
            }
        }
    }
}
