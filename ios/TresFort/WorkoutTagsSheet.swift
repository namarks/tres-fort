import SwiftUI

struct WorkoutTagsSheet: View {
    @ObservedObject var sync: SyncModel
    let workout: Workout
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var version = 0
    @State private var saving = false
    private var tags: [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
    }
    private var valid: Bool {
        tags.count <= 12 && tags.allSatisfy { $0.utf16.count <= 32 && !$0.unicodeScalars.contains { $0.value < 32 || $0.value == 127 } }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("travel, quick, bodyweight", text: $text, axis: .vertical)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("workoutTags.input")
                } header: { Text("Tags for \(workout.name)") }
                  footer: { Text("Separate tags with commas. Up to 12 tags, 32 characters each. Travel workouts appear first when choosing a workout during a trip.") }
                if !valid { Text("Use up to 12 short tags.").foregroundStyle(Theme.danger) }
                if let error = sync.loadError {
                    Text(error).foregroundStyle(Theme.danger)
                    Button("Reload saved tags") { reload() }
                        .disabled(saving || sync.isRoutineMutationInFlight)
                }
            }
            .navigationTitle("Workout tags")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            let accepted = await sync.saveWorkoutTags(dayID: workout.id, tags: tags, expectedVersion: version)
                            saving = false
                            if accepted { dismiss() }
                        }
                    }
                    .disabled(!valid || saving || sync.isRoutineMutationInFlight || version == 0)
                    .accessibilityIdentifier("workoutTags.save")
                }
            }
            .onAppear { reload() }
        }
        .interactiveDismissDisabled(saving)
        .preferredColorScheme(.dark)
    }
    private func reload() {
        text = (sync.workout(id: workout.id) ?? workout).workoutTags.joined(separator: ", ")
        version = sync.plan?.version ?? 0
    }
}
