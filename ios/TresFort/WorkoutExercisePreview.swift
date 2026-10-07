import SwiftUI

/// Shared prescription preview for saved workouts and calendar dates.
/// Keep group boundaries, targets, cues and demos identical at both entry points.
struct WorkoutExercisePreview: View {
    @ObservedObject var sync: SyncModel
    let exercises: [TemplateExercise]
    @State private var informationFor: TemplateExercise?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage(WeightUnit.preferenceKey) private var weightUnitRaw = "lb"
    private var weightUnit: WeightUnit { WeightUnit(rawValue: weightUnitRaw) ?? .lb }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 12) {
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
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .top, spacing: 10) {
                                ExerciseThumbnail(exerciseID: exercise.exercise_id,
                                    demoSlug: exercise.exercise_demo_slug ?? sync.catalogRow(exercise.exercise_id)?.demo_slug,
                                    jwt: sync.exerciseDemoJWT)
                                if dynamicTypeSize.isAccessibilitySize {
                                    Spacer(minLength: 0)
                                } else {
                                    prescription(exercise, member: block.isGroup ? block.memberLabel(at: index) : nil)
                                }
                                ExerciseInfoButton(exerciseName: exercise.exercise_name) { informationFor = exercise }
                            }
                            if dynamicTypeSize.isAccessibilitySize {
                                prescription(exercise, member: block.isGroup ? block.memberLabel(at: index) : nil)
                            }
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
        .sheet(item: $informationFor) { exercise in
            ExerciseInformationSheet(sync: sync, information: ExerciseInformation(
                prescription: exercise, catalog: sync.catalogRow(exercise.exercise_id)))
        }
    }

    private func prescription(_ exercise: TemplateExercise, member: String?) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let member {
                Text(member).font(Theme.mono(12, .bold)).foregroundStyle(Theme.accent)
            }
            Text(exercise.exercise_name)
                .font(.headline).foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
            if exercise.isWarmup { WarmupTag() }
            Text(exercise.prescriptionLabel(in: weightUnit))
                .font(Theme.mono(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let cues = exercise.cues, !cues.isEmpty {
                Text(cues).font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
