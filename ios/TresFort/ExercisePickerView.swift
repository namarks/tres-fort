import SwiftUI

enum ExerciseRegion: String, CaseIterable {
    case all = "All"
    case upper = "Upper body"
    case lower = "Lower body"
    case core = "Core"

    func includes(_ exercise: ExerciseCatalog) -> Bool {
        let muscle = ExerciseSearchPolicy.normalized(exercise.primary_muscle)
        switch self {
        case .all: return true
        case .upper: return ["chest", "back", "shoulders", "traps", "biceps", "triceps", "forearms", "arms"].contains(muscle)
        case .lower: return ["quads", "hamstrings", "glutes", "calves", "legs", "adductors", "abductors"].contains(muscle)
        case .core: return ["core", "abs", "abdominals", "obliques"].contains(muscle)
        }
    }
}

enum ExerciseSearchPolicy {
    static func normalized(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func results(_ catalog: [ExerciseCatalog], query: String, region: ExerciseRegion,
                        replacing: TemplateExercise? = nil) -> [ExerciseCatalog] {
        let terms = normalized(query).split(separator: " ")
        let preferredMuscle = replacing.flatMap { target in
            catalog.first { $0.id == target.exercise_id }.map { normalized($0.primary_muscle) }
        }
        return catalog.filter { exercise in
            if let replacing {
                guard exercise.id != replacing.exercise_id,
                      ["timed", "cardio"].contains(exercise.modality) == replacing.isTimed
                else { return false }
            }
            guard region.includes(exercise) else { return false }
            let aliases = exercise.aliases.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let text = normalized(([exercise.name, exercise.primary_muscle, exercise.modality,
                                    exercise.modality == "bw" ? "bodyweight" : ""] + aliases).joined(separator: " "))
            return terms.allSatisfy { text.contains($0) }
        }.sorted {
            if let preferredMuscle {
                let firstMatches = normalized($0.primary_muscle) == preferredMuscle
                let secondMatches = normalized($1.primary_muscle) == preferredMuscle
                if firstMatches != secondMatches { return firstMatches }
            }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    static func defaultName(existingNames: [String]) -> String {
        let used = Set(existingNames.map(normalized))
        var number = 1
        while used.contains(normalized("Workout \(number)")) { number += 1 }
        return "Workout \(number)"
    }

    static func initialTargets(for exercise: ExerciseCatalog) -> String {
        switch exercise.modality {
        case "cardio": return "5 min"
        case "timed": return "3 × 45 sec"
        default: return "3 × 8 reps"
        }
    }
}

struct ExerciseCatalogLabel: View {
    let exercise: ExerciseCatalog
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(exercise.name).font(Theme.mono(14, .bold)).foregroundStyle(Theme.text)
            Text("\(exercise.primary_muscle) · \(exercise.modality == "bw" ? "bodyweight" : exercise.modality)")
                .font(Theme.mono(11)).foregroundStyle(Theme.muted)
        }
    }
}

/// Shared lookup for creation, saved prescriptions and session swaps. Search and
/// region selection compose; selecting an exercise never resets either.
struct ExercisePickerList<Row: View>: View {
    @ObservedObject var sync: SyncModel
    var replacing: TemplateExercise? = nil
    private var catalog: [ExerciseCatalog] { sync.catalog }
    @State private var informationFor: ExerciseCatalog?
    @ViewBuilder var row: (ExerciseCatalog) -> Row
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    @State private var region: ExerciseRegion = .all
    @State private var refreshing = false

    private var matches: [ExerciseCatalog] {
        ExerciseSearchPolicy.results(catalog, query: query, region: region, replacing: replacing)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search exercises", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
                    .focused($searchFocused)
                    .onSubmit { searchFocused = false }
                    .accessibilityIdentifier("exercisePicker.search")
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Clear search")
                }
            }
            .padding(.leading, 14).frame(minHeight: 48)
            .background(Theme.surface).clipShape(RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal).padding(.top, 12)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ExerciseRegion.allCases, id: \.self) { option in
                        Button { region = option } label: {
                            Text(option.rawValue).font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 16).frame(minHeight: 44)
                                .foregroundStyle(region == option ? Theme.bg : Theme.text)
                                .background(region == option ? Theme.accent : Theme.surface)
                                .clipShape(Capsule())
                        }
                        .accessibilityAddTraits(region == option ? [.isSelected] : [])
                        .accessibilityIdentifier("exercisePicker.region.\(option)")
                    }
                }.padding(.horizontal)
            }.padding(.vertical, 12)
            .accessibilityIdentifier("exercisePicker.regions")
            List {
                if let replacing {
                    Section {
                        Text("Replace \(replacing.exercise_name) for this session only. Your saved workout and completed sets stay unchanged.")
                        Text("Keep \(replacing.targetLabel). Choose the replacement’s weight before logging your next set.")
                            .foregroundStyle(Theme.muted)
                    }
                    .listRowBackground(Theme.surface)
                }
                if catalog.isEmpty {
                    Section {
                        Text("Connect to load the exercise library.").foregroundStyle(Theme.muted)
                        Button(refreshing ? "Loading…" : "Reload exercises") {
                            refreshing = true
                            Task { await sync.load(); refreshing = false }
                        }.disabled(refreshing)
                    }
                } else if matches.isEmpty {
                    Section {
                        Text("No matching exercises").font(.headline)
                        Button("Clear search and filters") {
                            searchFocused = false
                            query = ""; region = .all
                        }
                        Text("Try another name, muscle, or equipment, or clear your filters.")
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Section(replacing == nil
                            ? "\(matches.count) exercise\(matches.count == 1 ? "" : "s")"
                            : "\(matches.count) compatible · matching muscle first") {
                        ForEach(matches) { exercise in
                            HStack(spacing: 8) {
                                row(exercise).frame(maxWidth: .infinity, alignment: .leading)
                                    .buttonStyle(.plain)
                                ExerciseInfoButton(exerciseName: exercise.name) {
                                    searchFocused = false
                                    informationFor = exercise
                                }
                            }
                            .listRowBackground(Theme.surface)
                        }
                    }
                }
            }
            .accessibilityIdentifier("exercisePicker.results")
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background).tint(Theme.accent)
        .sheet(item: $informationFor) { exercise in
            ExerciseInformationSheet(sync: sync, information: ExerciseInformation(exercise: exercise))
        }
    }
}
