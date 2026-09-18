import SwiftUI

struct WorkoutExerciseSwapSheet: View {
    @ObservedObject var sync: SyncModel
    let target: WorkoutSwapTarget
    @Environment(\.dismiss) private var dismiss
    @State private var selection: ExerciseCatalog?
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ExercisePickerList(sync: sync, replacing: target.exercise) { exercise in
                Button {
                    selection = exercise
                    error = nil
                } label: {
                    HStack {
                        ExerciseCatalogLabel(exercise: exercise)
                        Spacer()
                        if selection?.id == exercise.id {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                        }
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .accessibilityIdentifier("exercisePicker.exercise.\(exercise.id)")
                .accessibilityAddTraits(selection?.id == exercise.id ? [.isSelected] : [])
            }
            .disabled(saving)
            .navigationTitle("Swap exercise")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    if let error { Text(error).foregroundStyle(Theme.danger) }
                    if let selection {
                        Text("Replace \(target.exercise.exercise_name) with \(selection.name).")
                            .font(.subheadline).foregroundStyle(Theme.text)
                            .accessibilityIdentifier("runner.swap-selection")
                    }
                    Button {
                        guard let selection else { return }
                        saving = true
                        Task {
                            if await sync.swapWorkoutExercise(target, with: selection.id) { dismiss() }
                            else { error = sync.loadError ?? "This workout changed. Close and reopen Swap exercise." }
                            saving = false
                        }
                    } label: {
                        Text(saving ? "Saving…" : "Swap for this session")
                            .font(.headline).frame(maxWidth: .infinity, minHeight: 48)
                    }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(selection == nil || saving)
                    .accessibilityIdentifier("runner.confirm-swap")
                }
                .padding().background(Theme.background)
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
