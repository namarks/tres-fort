// Training load for endurance workouts (docs/plans/endurance-training-load).
//
// Pure functions only: no D1, no I/O. Every scale is anchored so that one hour
// at the athlete's threshold is a load of 100 and an intensity of 100%:
//
//   power:       load = hours × (NP / FTP)² × 100          (NP = normalized power)
//   heart rate:  load = Σ seconds × (HR / threshold HR)² / 3600 × 100
//   pace:        load = hours × (threshold pace / pace)² × 100
//
// Heart-rate load is Tres Fort's own figure, not intervals.icu's TRIMP-based
// one; a provider's load is preferred whenever the source supplies it. Sparse
// streams are refused rather than stretched: a gap longer than
// MAX_SAMPLE_GAP_SEC is a recording pause, and a stream that covers less than
// MIN_STREAM_COVERAGE of the workout yields no stream-based load.

export type LoadMethod =
  | 'provider'
  | 'power'
  | 'power_summary'
  | 'heart_rate'
  | 'heart_rate_average'
  | 'pace';

/** One sample: `t` seconds from the workout start (ascending), `v` the value. */
export interface Sample {
  t: number;
  v: number;
}

export interface LoadResult {
  /** Rounded to a whole number, like intervals.icu's `icu_training_load`. */
  load: number;
  /** Percent of threshold (100 = at threshold), one decimal; null when unknown. */
  intensity: number | null;
  method: LoadMethod;
}

export interface ThresholdSet {
  ftp_w?: number | null;
  threshold_hr?: number | null;
  threshold_pace_s_per_km?: number | null;
}

export interface LoadInput {
  /** Moving time of the workout; streams must cover enough of it. */
  moving_time_sec: number | null;
  distance_m?: number | null;
  average_hr?: number | null;
  /** Normalized power computed by the source, when it supplies one. */
  weighted_avg_watts?: number | null;
  provider_load?: number | null;
  provider_intensity?: number | null;
  power_samples?: readonly Sample[] | null;
  hr_samples?: readonly Sample[] | null;
}

export const MAX_SAMPLE_GAP_SEC = 10;
export const MIN_STREAM_COVERAGE = 0.8;
const NP_WINDOW_SEC = 30;

const positive = (v: number | null | undefined): v is number =>
  typeof v === 'number' && Number.isFinite(v) && v > 0;

const round1 = (v: number) => Math.round(v * 10) / 10;

function result(load: number, intensityRatio: number | null, method: LoadMethod): LoadResult | null {
  if (!Number.isFinite(load) || load < 0) return null;
  return {
    load: Math.round(load),
    intensity: intensityRatio === null || !Number.isFinite(intensityRatio) ? null : round1(intensityRatio * 100),
    method,
  };
}

/** Keep finite, non-negative samples in time order; drop duplicate times. */
function clean(samples: readonly Sample[]): Sample[] {
  const ok = samples.filter(s => Number.isFinite(s.t) && Number.isFinite(s.v) && s.v >= 0);
  ok.sort((a, b) => a.t - b.t);
  const out: Sample[] = [];
  let last = -Infinity;
  for (const s of ok) {
    if (s.t > last) out.push(s);
    last = s.t;
  }
  return out;
}

interface Span {
  t: number;
  v: number;
  /** Seconds this sample holds: until the next sample, or 1 before a pause. */
  dt: number;
  /** A pause (or the end of the stream) follows this sample. */
  ends: boolean;
}

function spans(samples: readonly Sample[], maxGap: number): Span[] {
  const s = clean(samples);
  return s.map((cur, i) => {
    const next = s[i + 1];
    const gap = next ? next.t - cur.t : Infinity;
    return gap <= maxGap ? { t: cur.t, v: cur.v, dt: gap, ends: false } : { t: cur.t, v: cur.v, dt: 1, ends: true };
  });
}

/** Seconds the stream covers: each sample holds until the next one, unless
 * the gap is a pause. The last sample of each run counts one second. */
export function coveredSeconds(samples: readonly Sample[], maxGap = MAX_SAMPLE_GAP_SEC): number {
  return spans(samples, maxGap).reduce((sum, span) => sum + span.dt, 0);
}

function coverageOk(samples: readonly Sample[], movingSec: number | null): boolean {
  const covered = coveredSeconds(samples);
  if (covered < NP_WINDOW_SEC) return false;
  return !positive(movingSec) || covered / movingSec >= MIN_STREAM_COVERAGE;
}

/** Normalized power: power resampled to 1-second bins within each
 * continuous run of samples (each bin is the time-weighted mean of the
 * readings that hold during it, so faster-than-1 Hz streams count every
 * reading), then a 30-second rolling average, fourth-power mean and fourth
 * root. Null when no run is at least 30 seconds long. */
export function normalizedPower(samples: readonly Sample[], maxGap = MAX_SAMPLE_GAP_SEC): number | null {
  let sum4 = 0;
  let count = 0;
  const rolling = (bins: number[]) => {
    let windowSum = 0;
    bins.forEach((watts, i) => {
      windowSum += watts - (i >= NP_WINDOW_SEC ? bins[i - NP_WINDOW_SEC] ?? 0 : 0);
      if (i >= NP_WINDOW_SEC - 1) {
        sum4 += (windowSum / NP_WINDOW_SEC) ** 4;
        count += 1;
      }
    });
  };
  let run: Span[] = [];
  const flush = () => {
    const first = run[0];
    const last = run[run.length - 1];
    if (first && last) {
      const n = Math.ceil(last.t + last.dt - first.t - 1e-9);
      const energy = new Array<number>(n).fill(0);
      const time = new Array<number>(n).fill(0);
      for (const span of run) {
        let from = span.t - first.t;
        const to = from + span.dt;
        while (from < to - 1e-9) {
          const bin = Math.floor(from + 1e-9);
          const until = Math.min(to, bin + 1);
          if (bin < n) {
            energy[bin] = (energy[bin] ?? 0) + span.v * (until - from);
            time[bin] = (time[bin] ?? 0) + (until - from);
          }
          from = until;
        }
      }
      rolling(energy.map((e, i) => {
        const t = time[i] ?? 0;
        return t > 0 ? e / t : 0;
      }));
    }
    run = [];
  };
  for (const span of spans(samples, maxGap)) {
    run.push(span);
    if (span.ends) flush();
  }
  flush();
  return count === 0 ? null : (sum4 / count) ** 0.25;
}

/** Load from normalized power over the moving time. Zero normalized power
 * counts as no power data, not as a zero load: a whole workout at 0 W (or a
 * source reporting 0) means a meter that was paired but not measuring, and
 * coasting inside a ride already lowers NP without zeroing it. The selector
 * then falls through to heart rate or pace. */
export function powerSummaryLoad(normalizedWatts: number | null | undefined, movingSec: number | null, ftp: number | null | undefined, method: LoadMethod = 'power_summary'): LoadResult | null {
  if (!positive(normalizedWatts) || !positive(movingSec) || !positive(ftp)) return null;
  const ratio = normalizedWatts / ftp;
  return result((movingSec / 3600) * ratio * ratio * 100, ratio, method);
}

/** Load from a power stream; null when the stream is too sparse. */
export function powerStreamLoad(samples: readonly Sample[], movingSec: number | null, ftp: number | null | undefined): LoadResult | null {
  if (!positive(ftp) || !coverageOk(samples, movingSec)) return null;
  const np = normalizedPower(samples);
  const seconds = positive(movingSec) ? movingSec : coveredSeconds(samples);
  return powerSummaryLoad(np, seconds, ftp, 'power');
}

/** Load from a heart-rate stream; null when the stream is too sparse. */
export function heartRateStreamLoad(samples: readonly Sample[], movingSec: number | null, thresholdHr: number | null | undefined, maxGap = MAX_SAMPLE_GAP_SEC): LoadResult | null {
  // A zero heart rate is a sensor dropout, not a reading: drop it so it leaves
  // a gap (and counts against coverage) instead of diluting the load. Zero
  // power, by contrast, is real coasting and stays in the power path.
  const readings = samples.filter(s => s.v > 0);
  if (!positive(thresholdHr) || !coverageOk(readings, movingSec)) return null;
  let weighted = 0;
  let seconds = 0;
  for (const span of spans(readings, maxGap)) {
    const ratio = span.v / thresholdHr;
    weighted += span.dt * ratio * ratio;
    seconds += span.dt;
  }
  if (seconds <= 0) return null;
  return result((weighted / 3600) * 100, Math.sqrt(weighted / seconds), 'heart_rate');
}

/** Fallback from average heart rate when no usable stream exists. */
export function averageHeartRateLoad(averageHr: number | null | undefined, movingSec: number | null, thresholdHr: number | null | undefined): LoadResult | null {
  if (!positive(averageHr) || !positive(movingSec) || !positive(thresholdHr)) return null;
  const ratio = averageHr / thresholdHr;
  return result((movingSec / 3600) * ratio * ratio * 100, ratio, 'heart_rate_average');
}

/** Run load from average pace against threshold pace. */
export function paceLoad(distanceM: number | null | undefined, movingSec: number | null, thresholdPaceSPerKm: number | null | undefined): LoadResult | null {
  if (!positive(distanceM) || !positive(movingSec) || !positive(thresholdPaceSPerKm)) return null;
  const pace = movingSec / (distanceM / 1000);
  const ratio = thresholdPaceSPerKm / pace;
  return result((movingSec / 3600) * ratio * ratio * 100, ratio, 'pace');
}

/**
 * The best available load, in this order: the provider's own figure, a power
 * stream, the source's normalized power, a heart-rate stream, pace, average
 * heart rate. Each method runs only when its threshold is set. Null means no
 * usable data: callers show the load as unknown, never as zero.
 */
export function selectLoad(input: LoadInput, thresholds: ThresholdSet): LoadResult | null {
  if (typeof input.provider_load === 'number' && Number.isFinite(input.provider_load) && input.provider_load >= 0) {
    // Rounded exactly as migration 0060 and the intervals.icu upsert store
    // it, so an unchanged provider row never needs a rewrite.
    return {
      load: Math.round(input.provider_load),
      intensity: positive(input.provider_intensity) ? round1(input.provider_intensity) : null,
      method: 'provider',
    };
  }
  const moving = positive(input.moving_time_sec) ? input.moving_time_sec : null;
  return (
    (input.power_samples ? powerStreamLoad(input.power_samples, moving, thresholds.ftp_w) : null)
    ?? powerSummaryLoad(input.weighted_avg_watts, moving, thresholds.ftp_w)
    ?? (input.hr_samples ? heartRateStreamLoad(input.hr_samples, moving, thresholds.threshold_hr) : null)
    ?? paceLoad(input.distance_m, moving, thresholds.threshold_pace_s_per_km)
    ?? averageHeartRateLoad(input.average_hr, moving, thresholds.threshold_hr)
  );
}
