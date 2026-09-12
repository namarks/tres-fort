import SwiftUI

struct WorkoutExerciseSwapSheet: View {
    @ObservedObject var sync: SyncModel
    let target: WorkoutSwapTarget
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selection: ExerciseCatalog?
    @State private var saving = false
    @State private var error: String?

    private var choices: [ExerciseCatalog] {
        let muscle = sync.catalogRow(target.exercise.exercise_id)?.primary_muscle
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return sync.catalog.filter {
            $0.id != target.exercise.exercise_id
                && ["timed", "cardio"].contains($0.modality) == target.exercise.isTimed
                && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search)
                    || $0.primary_muscle.localizedCaseInsensitiveContains(search)
                    || $0.modality.localizedCaseInsensitiveContains(search))
        }.sorted {
            if ($0.primary_muscle == muscle) != ($1.primary_muscle == muscle) {
                return $0.primary_muscle == muscle
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Replace \(target.exercise.exercise_name) for this workout. Your routine and completed sets stay saved.")
                    Text("Keep \(target.exercise.targetLabel). Choose the replacement’s weight before logging your next set.")
                        .foregroundStyle(Theme.muted)
                }
                .listRowBackground(Theme.surface)
                Section(target.exercise.isTimed ? "Timed exercises" : "Exercises · matching muscle first") {
                    ForEach(choices) { exercise in
                        Button {
                            selection = exercise
                            error = nil
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(exercise.name).foregroundStyle(Theme.text)
                                    Text("\(exercise.primary_muscle) · \(exercise.modality)")
                                        .font(.caption).foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                if selection?.id == exercise.id {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .listRowBackground(Theme.surface)
                    }
                    if choices.isEmpty {
                        Text(sync.catalog.isEmpty ? "Connect to load exercises, then try again." : "No matching exercises.")
                            .foregroundStyle(Theme.muted)
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.danger) }
            }
            .disabled(saving)
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .searchable(text: $query, prompt: "Search name, muscle, or equipment")
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                Button {
                    guard let selection else { return }
                    saving = true
                    Task {
                        if await sync.swapWorkoutExercise(target, with: selection.id) { dismiss() }
                        else { error = sync.loadError ?? "This workout changed. Close and reopen Swap exercise." }
                        saving = false
                    }
                } label: {
                    Text(saving ? "Saving…" : "Swap for this workout")
                        .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(selection == nil || saving)
                .padding().background(Theme.background)
                .accessibilityIdentifier("runner.confirm-swap")
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .preferredColorScheme(.dark)
    }
}
