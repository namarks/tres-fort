import SwiftUI

/// Shared prescription preview for saved workouts and calendar dates.
/// Keep group boundaries, targets, cues and demos identical at both entry points.
struct WorkoutExercisePreview: View {
    @ObservedObject var sync: SyncModel
    let exercises: [TemplateExercise]
    @State private var demoFor: TemplateExercise?
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .lb }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(ExerciseGroupBlock.blocks(exercises)) { block in
                VStack(alignment: .leading, spacing: 12) {
                    if block.isGroup {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(block.title)
                                .font(.headline).foregroundStyle(Theme.accent)
                                .accessibilityAddTraits(.isHeader)
                            Text("\(block.rounds) rounds · \(block.roundRest)s round rest")
                                .font(.caption).foregroundStyle(Theme.muted)
                            if block.transitionRest > 0 {
                                Text("\(block.transitionRest)s between exercises")
                                    .font(.caption).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                    ForEach(Array(block.members.enumerated()), id: \.element.id) { index, exercise in
                        if index > 0 { Divider().overlay(Theme.surface2) }
                        HStack(alignment: .top, spacing: 8) {
                            if block.isGroup {
                                Text(block.memberLabel(at: index))
                                    .font(Theme.mono(12, .bold))
                                    .foregroundStyle(Theme.accent)
                                    .padding(.top, 3)
                            }
                            VStack(alignment: .leading, spacing: 5) {
                                Text(exercise.exercise_name)
                                    .font(.headline).foregroundStyle(Theme.text)
                                    .fixedSize(horizontal: false, vertical: true)
                                if exercise.isWarmup { WarmupTag() }
                                Text(exercise.prescriptionLabel(in: weightUnit))
                                    .font(Theme.mono(13)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                if let cues = exercise.cues, !cues.isEmpty {
                                    Text(cues)
                                        .font(.caption).foregroundStyle(Theme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            DemoInfoButton(exerciseName: exercise.exercise_name) { demoFor = exercise }
                        }
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("workoutPreview.exercise.\(exercise.id)")
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("workoutPreview.\(block.id)")
            }
        }
        .sheet(item: $demoFor) { exercise in
            ExerciseDemoSheet(
                exerciseID: exercise.exercise_id, name: exercise.exercise_name,
                primaryMuscle: sync.catalogRow(exercise.exercise_id)?.primary_muscle ?? exercise.exercise_modality,
                secondaryMuscles: [], modality: exercise.exercise_modality,
                laterality: exercise.exercise_laterality ?? "bilateral",
                loadMode: exercise.exercise_load_mode ?? "total",
                demoSlug: exercise.exercise_demo_slug, jwt: sync.exerciseDemoJWT)
        }
    }
}
