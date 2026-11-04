import HealthKit

/// What a workout actually was (soccer, tennis, a swim), beside the coarse
/// `kind` the importers use for cross-source dedup. Mirrors `src/sports.ts`;
/// both are pinned to `TresFortTests/Fixtures/Sports.json`
/// (docs/plans/sport-activities P0).
struct Sport: Equatable, Identifiable {
    let id: String
    let label: String
    /// SF Symbol.
    let glyph: String
}

enum Sports {
    /// Every sport, in the server's order.
    static let all: [Sport] = [
        Sport(id: "run", label: "Run", glyph: "figure.run"),
        Sport(id: "ride", label: "Ride", glyph: "bicycle"),
        Sport(id: "swim", label: "Swim", glyph: "figure.pool.swim"),
        Sport(id: "walk", label: "Walk", glyph: "figure.walk"),
        Sport(id: "hike", label: "Hike", glyph: "figure.hiking"),
        Sport(id: "row", label: "Row", glyph: "figure.rower"),
        Sport(id: "elliptical", label: "Elliptical", glyph: "figure.elliptical"),
        Sport(id: "stairs", label: "Stair stepper", glyph: "figure.stair.stepper"),
        Sport(id: "cardio", label: "Cardio", glyph: "figure.mixed.cardio"),
        Sport(id: "hiit", label: "HIIT", glyph: "figure.highintensity.intervaltraining"),
        Sport(id: "cross_training", label: "Cross training", glyph: "figure.cross.training"),
        Sport(id: "strength", label: "Strength", glyph: "dumbbell.fill"),
        Sport(id: "core", label: "Core", glyph: "figure.core.training"),
        Sport(id: "yoga", label: "Yoga", glyph: "figure.yoga"),
        Sport(id: "pilates", label: "Pilates", glyph: "figure.pilates"),
        Sport(id: "barre", label: "Barre", glyph: "figure.barre"),
        Sport(id: "flexibility", label: "Stretching", glyph: "figure.flexibility"),
        Sport(id: "dance", label: "Dance", glyph: "figure.dance"),
        Sport(id: "boxing", label: "Boxing", glyph: "figure.boxing"),
        Sport(id: "martial_arts", label: "Martial arts", glyph: "figure.martial.arts"),
        Sport(id: "climbing", label: "Climbing", glyph: "figure.climbing"),
        Sport(id: "soccer", label: "Soccer", glyph: "figure.soccer"),
        Sport(id: "basketball", label: "Basketball", glyph: "figure.basketball"),
        Sport(id: "volleyball", label: "Volleyball", glyph: "figure.volleyball"),
        Sport(id: "american_football", label: "Football", glyph: "figure.american.football"),
        Sport(id: "rugby", label: "Rugby", glyph: "figure.rugby"),
        Sport(id: "hockey", label: "Hockey", glyph: "figure.hockey"),
        Sport(id: "lacrosse", label: "Lacrosse", glyph: "figure.lacrosse"),
        Sport(id: "handball", label: "Handball", glyph: "figure.handball"),
        Sport(id: "baseball", label: "Baseball", glyph: "figure.baseball"),
        Sport(id: "softball", label: "Softball", glyph: "figure.softball"),
        Sport(id: "cricket", label: "Cricket", glyph: "figure.cricket"),
        Sport(id: "disc_sports", label: "Ultimate", glyph: "figure.disc.sports"),
        Sport(id: "tennis", label: "Tennis", glyph: "figure.tennis"),
        Sport(id: "pickleball", label: "Pickleball", glyph: "figure.pickleball"),
        Sport(id: "padel", label: "Padel", glyph: "figure.tennis"),
        Sport(id: "squash", label: "Squash", glyph: "figure.squash"),
        Sport(id: "racquetball", label: "Racquetball", glyph: "figure.racquetball"),
        Sport(id: "badminton", label: "Badminton", glyph: "figure.badminton"),
        Sport(id: "table_tennis", label: "Table tennis", glyph: "figure.table.tennis"),
        Sport(id: "golf", label: "Golf", glyph: "figure.golf"),
        Sport(id: "skating", label: "Skating", glyph: "figure.skating"),
        Sport(id: "downhill_ski", label: "Skiing", glyph: "figure.skiing.downhill"),
        Sport(id: "cross_country_ski", label: "Cross-country ski", glyph: "figure.skiing.crosscountry"),
        Sport(id: "snowboard", label: "Snowboard", glyph: "figure.snowboarding"),
        Sport(id: "paddling", label: "Paddling", glyph: "oar.2.crossed"),
        Sport(id: "surfing", label: "Surfing", glyph: "figure.surfing"),
        Sport(id: "sailing", label: "Sailing", glyph: "figure.sailing"),
        Sport(id: "jump_rope", label: "Jump rope", glyph: "figure.jumprope"),
        Sport(id: "other", label: "Other", glyph: "figure.mixed.cardio"),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    static func sport(id: String?) -> Sport? { id.flatMap { byID[$0] } }

    /// A known sport other than "other": one worth naming over a generic title.
    static func named(_ id: String?) -> Sport? {
        guard let sport = sport(id: id), sport.id != "other" else { return nil }
        return sport
    }

    /// An activity's title: its own name, else its sport, else a humanised
    /// kind. "Workout" is the name an older app gave every Apple Health sport
    /// it didn't know, so a known sport replaces it.
    static func title(name: String?, sport: String?, kind: String) -> String {
        let known = named(sport)
        if let name, !name.isEmpty, !(name == "Workout" && known != nil) { return name }
        return known?.label ?? kind.capitalized
    }

    /// The sport a planned activity's name stands for ("Soccer", "soccer",
    /// "Table tennis"), when it names one.
    static func matching(name: String) -> Sport? {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return all.first { $0.id != "other" && ($0.label.lowercased() == key || $0.id == key) }
    }

    /// Sports the Worker scores from heart rate (sport-activities P1), so the
    /// Apple Health import reads their heart-rate samples. Mirrors
    /// `HEART_RATE_THRESHOLDS` in src/sports.ts.
    static let heartRateScored: Set<String> = [
        "run", "ride", "walk", "hike", "elliptical", "stairs", "cardio", "hiit", "cross_training",
        "dance", "boxing", "martial_arts", "climbing", "soccer", "basketball", "volleyball",
        "american_football", "rugby", "hockey", "lacrosse", "handball", "baseball", "softball",
        "cricket", "disc_sports", "tennis", "pickleball", "padel", "squash", "racquetball",
        "badminton", "table_tennis", "skating", "downhill_ski", "cross_country_ski", "snowboard",
        "jump_rope"
    ]

    static func scoresHeartRate(_ id: String?) -> Bool {
        id.map(heartRateScored.contains) ?? false
    }

    /// The sport of an Apple Health workout. Types not listed are "other".
    static func sport(for type: HKWorkoutActivityType) -> String {
        // 14 is the deprecated `.dance`, matched by number to avoid the warning.
        if type.rawValue == 14 { return "dance" }
        switch type {
        case .americanFootball: return "american_football"
        case .badminton: return "badminton"
        case .baseball: return "baseball"
        case .basketball: return "basketball"
        case .boxing, .kickboxing: return "boxing"
        case .climbing: return "climbing"
        case .cricket: return "cricket"
        case .crossTraining: return "cross_training"
        case .cycling: return "ride"
        case .cardioDance, .socialDance: return "dance"
        case .elliptical: return "elliptical"
        case .functionalStrengthTraining, .traditionalStrengthTraining: return "strength"
        case .golf: return "golf"
        case .handball: return "handball"
        case .hiking: return "hike"
        case .hockey: return "hockey"
        case .lacrosse: return "lacrosse"
        case .martialArts: return "martial_arts"
        case .paddleSports: return "paddling"
        case .racquetball: return "racquetball"
        case .rowing: return "row"
        case .rugby: return "rugby"
        case .running: return "run"
        case .sailing: return "sailing"
        case .skatingSports: return "skating"
        case .soccer: return "soccer"
        case .softball: return "softball"
        case .squash: return "squash"
        case .stairClimbing, .stairs: return "stairs"
        case .surfingSports: return "surfing"
        case .swimming: return "swim"
        case .tableTennis: return "table_tennis"
        case .tennis: return "tennis"
        case .volleyball: return "volleyball"
        case .walking: return "walk"
        case .yoga: return "yoga"
        case .barre: return "barre"
        case .coreTraining: return "core"
        case .crossCountrySkiing: return "cross_country_ski"
        case .downhillSkiing: return "downhill_ski"
        case .flexibility: return "flexibility"
        case .highIntensityIntervalTraining: return "hiit"
        case .jumpRope: return "jump_rope"
        case .pilates: return "pilates"
        case .snowboarding: return "snowboard"
        case .mixedCardio: return "cardio"
        case .discSports: return "disc_sports"
        case .pickleball: return "pickleball"
        default: return "other"
        }
    }
}
