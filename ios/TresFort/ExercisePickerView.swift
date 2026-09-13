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

    static func results(_ catalog: [ExerciseCatalog], query: String, region: ExerciseRegion) -> [ExerciseCatalog] {
        let terms = normalized(query).split(separator: " ")
        return catalog.filter { exercise in
            guard region.includes(exercise) else { return false }
            let aliases = exercise.aliases.flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
            let text = normalized(([exercise.name, exercise.primary_muscle, exercise.modality,
                                    exercise.modality == "bw" ? "bodyweight" : ""] + aliases).joined(separator: " "))
            return terms.allSatisfy { text.contains($0) }
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
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

/// Shared lookup for creation and adding a saved prescription. Search and
/// region selection compose; selecting an exercise never resets either.
struct ExercisePickerList<Row: View>: View {
    let catalog: [ExerciseCatalog]
    let reload: () async -> Void
    @ViewBuilder var row: (ExerciseCatalog) -> Row
    @State private var query = ""
    @State private var region: ExerciseRegion = .all
    @State private var refreshing = false

    private var matches: [ExerciseCatalog] {
        ExerciseSearchPolicy.results(catalog, query: query, region: region)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(Theme.muted)
                TextField("Search exercises", text: $query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .submitLabel(.search)
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
            List {
                if catalog.isEmpty {
                    Section {
                        Text("Connect to load the exercise library.").foregroundStyle(Theme.muted)
                        Button(refreshing ? "Loading…" : "Reload exercises") {
                            refreshing = true
                            Task { await reload(); refreshing = false }
                        }.disabled(refreshing)
                    }
                } else if matches.isEmpty {
                    Section {
                        Text("No matching exercises").font(.headline)
                        Button("Clear search and filters") { query = ""; region = .all }
                        Text("Try another name, muscle, or equipment, or clear your filters.")
                            .foregroundStyle(Theme.muted)
                    }
                } else {
                    Section("\(matches.count) exercise\(matches.count == 1 ? "" : "s")") {
                        ForEach(matches) { exercise in
                            row(exercise).listRowBackground(Theme.surface)
                        }
                    }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollContentBackground(.hidden)
        }
        .background(Theme.background).tint(Theme.accent)
    }
}
