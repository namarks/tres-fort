// The sport vocabulary: what a workout actually was (soccer, tennis, a swim),
// beside the coarse `kind` the importers use for cross-source dedup. Pure
// data and lookups, no I/O. `ios/TresFort/Sports.swift` mirrors it; both are
// pinned to `ios/TresFortTests/Fixtures/Sports.json`, and migration 0064's
// backfill tables are pinned to these maps by test/sports.test.ts.
//
// `kind` stays as it is: dedup matches on kind + start time, so a finer kind
// would split one workout into two whenever two sources or app builds
// disagreed. `sport` is display and planning truth only.

export interface Sport {
  id: string;
  label: string;
}

/** Every sport, in the order a picker lists them after the member's own. */
export const SPORTS: readonly Sport[] = [
  { id: 'run', label: 'Run' },
  { id: 'ride', label: 'Ride' },
  { id: 'swim', label: 'Swim' },
  { id: 'walk', label: 'Walk' },
  { id: 'hike', label: 'Hike' },
  { id: 'row', label: 'Row' },
  { id: 'elliptical', label: 'Elliptical' },
  { id: 'stairs', label: 'Stair stepper' },
  { id: 'cardio', label: 'Cardio' },
  { id: 'hiit', label: 'HIIT' },
  { id: 'cross_training', label: 'Cross training' },
  { id: 'strength', label: 'Strength' },
  { id: 'core', label: 'Core' },
  { id: 'yoga', label: 'Yoga' },
  { id: 'pilates', label: 'Pilates' },
  { id: 'barre', label: 'Barre' },
  { id: 'flexibility', label: 'Stretching' },
  { id: 'dance', label: 'Dance' },
  { id: 'boxing', label: 'Boxing' },
  { id: 'martial_arts', label: 'Martial arts' },
  { id: 'climbing', label: 'Climbing' },
  { id: 'soccer', label: 'Soccer' },
  { id: 'basketball', label: 'Basketball' },
  { id: 'volleyball', label: 'Volleyball' },
  { id: 'american_football', label: 'Football' },
  { id: 'rugby', label: 'Rugby' },
  { id: 'hockey', label: 'Hockey' },
  { id: 'lacrosse', label: 'Lacrosse' },
  { id: 'handball', label: 'Handball' },
  { id: 'baseball', label: 'Baseball' },
  { id: 'softball', label: 'Softball' },
  { id: 'cricket', label: 'Cricket' },
  { id: 'disc_sports', label: 'Ultimate' },
  { id: 'tennis', label: 'Tennis' },
  { id: 'pickleball', label: 'Pickleball' },
  { id: 'padel', label: 'Padel' },
  { id: 'squash', label: 'Squash' },
  { id: 'racquetball', label: 'Racquetball' },
  { id: 'badminton', label: 'Badminton' },
  { id: 'table_tennis', label: 'Table tennis' },
  { id: 'golf', label: 'Golf' },
  { id: 'skating', label: 'Skating' },
  { id: 'downhill_ski', label: 'Skiing' },
  { id: 'cross_country_ski', label: 'Cross-country ski' },
  { id: 'snowboard', label: 'Snowboard' },
  { id: 'paddling', label: 'Paddling' },
  { id: 'surfing', label: 'Surfing' },
  { id: 'sailing', label: 'Sailing' },
  { id: 'jump_rope', label: 'Jump rope' },
  { id: 'other', label: 'Other' },
];

const LABELS = new Map(SPORTS.map(s => [s.id, s.label]));

export function isSport(id: unknown): id is string {
  return typeof id === 'string' && LABELS.has(id);
}

export function sportLabel(id: string): string | null {
  return LABELS.get(id) ?? null;
}

/** A coarse kind that is also a sport id stands in when nothing finer is known. */
function fromKind(kind: string): string {
  return isSport(kind) ? kind : 'other';
}

/**
 * `HKWorkoutActivityType` raw values (stable across iOS releases; the Swift
 * side maps the named cases and its test checks these numbers). Types not
 * listed are 'other'.
 */
export const HEALTHKIT_SPORTS: Readonly<Record<number, string>> = {
  1: 'american_football',
  4: 'badminton',
  5: 'baseball',
  6: 'basketball',
  8: 'boxing',
  9: 'climbing',
  10: 'cricket',
  11: 'cross_training',
  13: 'ride',
  14: 'dance',
  16: 'elliptical',
  20: 'strength',
  21: 'golf',
  23: 'handball',
  24: 'hike',
  25: 'hockey',
  27: 'lacrosse',
  28: 'martial_arts',
  31: 'paddling',
  34: 'racquetball',
  35: 'row',
  36: 'rugby',
  37: 'run',
  38: 'sailing',
  39: 'skating',
  41: 'soccer',
  42: 'softball',
  43: 'squash',
  44: 'stairs',
  45: 'surfing',
  46: 'swim',
  47: 'table_tennis',
  48: 'tennis',
  50: 'strength',
  51: 'volleyball',
  52: 'walk',
  57: 'yoga',
  58: 'barre',
  59: 'core',
  60: 'cross_country_ski',
  61: 'downhill_ski',
  62: 'flexibility',
  63: 'hiit',
  64: 'jump_rope',
  65: 'boxing',
  66: 'pilates',
  67: 'snowboard',
  68: 'stairs',
  73: 'cardio',
  75: 'disc_sports',
  77: 'dance',
  78: 'dance',
  79: 'pickleball',
};

/** The sport of an Apple Health workout from its activity type number. */
export function sportForHealthKitType(type: unknown, kind: string): string {
  if (typeof type === 'number' && Number.isInteger(type)) return HEALTHKIT_SPORTS[type] ?? 'other';
  return fromKind(kind);
}

/** intervals.icu activity `type` (Strava's sport types plus its own). */
export const INTERVALS_SPORTS: Readonly<Record<string, string>> = {
  Ride: 'ride',
  VirtualRide: 'ride',
  GravelRide: 'ride',
  MountainBikeRide: 'ride',
  EBikeRide: 'ride',
  EMountainBikeRide: 'ride',
  Velomobile: 'ride',
  Handcycle: 'ride',
  TrackRide: 'ride',
  Run: 'run',
  TrailRun: 'run',
  VirtualRun: 'run',
  Swim: 'swim',
  OpenWaterSwim: 'swim',
  Walk: 'walk',
  Hike: 'hike',
  Rowing: 'row',
  VirtualRow: 'row',
  Elliptical: 'elliptical',
  StairStepper: 'stairs',
  WeightTraining: 'strength',
  HighIntensityIntervalTraining: 'hiit',
  Crossfit: 'cross_training',
  Yoga: 'yoga',
  Pilates: 'pilates',
  RockClimbing: 'climbing',
  Soccer: 'soccer',
  Basketball: 'basketball',
  Volleyball: 'volleyball',
  Rugby: 'rugby',
  Hockey: 'hockey',
  Cricket: 'cricket',
  Baseball: 'baseball',
  Softball: 'softball',
  Tennis: 'tennis',
  Pickleball: 'pickleball',
  Padel: 'padel',
  Squash: 'squash',
  Racquetball: 'racquetball',
  Badminton: 'badminton',
  TableTennis: 'table_tennis',
  Golf: 'golf',
  Dance: 'dance',
  Boxing: 'boxing',
  IceSkate: 'skating',
  InlineSkate: 'skating',
  AlpineSki: 'downhill_ski',
  BackcountrySki: 'downhill_ski',
  NordicSki: 'cross_country_ski',
  RollerSki: 'cross_country_ski',
  Snowboard: 'snowboard',
  Canoeing: 'paddling',
  Kayaking: 'paddling',
  StandUpPaddling: 'paddling',
  Surfing: 'surfing',
  Kitesurf: 'surfing',
  Windsurf: 'surfing',
  Sail: 'sailing',
  Workout: 'other',
};

/** The sport of an intervals.icu activity from its `type`. */
export function sportForIntervalsType(type: unknown, kind: string): string {
  if (typeof type === 'string' && Object.prototype.hasOwnProperty.call(INTERVALS_SPORTS, type)) return INTERVALS_SPORTS[type]!;
  return fromKind(kind);
}

/** FIT `sport` (and `sub_sport` where it names the activity) to a sport. */
export function sportForFit(sport: number | null, subSport: number | null, kind: string): string {
  switch (sport) {
    case 6: return 'basketball';
    case 7: return 'soccer';
    case 8: return 'tennis';
    case 9: return 'american_football';
    case 10: // training
      if (subSport === 20) return 'strength';
      if (subSport === 26) return 'cardio';
      if (subSport === 43) return 'yoga';
      if (subSport === 44) return 'pilates';
      return 'other';
    case 12: return 'cross_country_ski';
    case 13: return 'downhill_ski';
    case 14: return 'snowboard';
    case 19: case 37: case 41: return 'paddling';
    case 25: return 'golf';
    case 30: case 33: return 'skating';
    case 31: return 'climbing';
    case 32: return 'sailing';
    case 38: return 'surfing';
    case 47: return 'boxing';
    case 49: return 'baseball';
    case 4: // fitness equipment
      if (subSport === 16) return 'stairs';
      return fromKind(kind);
    default: return fromKind(kind);
  }
}

/** The HealthKit activity type number the app keeps in an import's `raw`. */
export function healthKitTypeOf(raw: string | null): number | null {
  if (!raw) return null;
  try {
    const v = (JSON.parse(raw) as { hk_activity_type?: unknown }).hk_activity_type;
    return typeof v === 'number' && Number.isInteger(v) ? v : null;
  } catch {
    return null;
  }
}
