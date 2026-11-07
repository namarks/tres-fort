// A planned run's laps on the web (docs/plans/planned-runs P9), as the
// iPhone app shows them on the run's detail (RunLapsView.swift): each step
// on its own line, with its time, distance, pace and heart rate, and how it
// went against the step's target. Pure: RouteMapView.tsx draws them.
import type { RunLap } from '../../src/runLaps';
import type { RunStepKind, RunStepTarget } from '../../src/runSteps';
import { paceText } from './runPlan';

export type { RunLap };

export type LapVerdict = 'on_target' | 'fast' | 'slow' | 'high' | 'low';

export interface LapRow {
  kind: RunStepKind | null;
  title: string;
  /** "Skipped" or "Ended early"; null for a step run in full. */
  note: string | null;
  figures: string;
  /** "Pace 6:10–6:26 /mi · slower"; null without a target. */
  target: string | null;
  verdict: LapVerdict | null;
}

const KIND_TITLES: Record<RunStepKind, string> = {
  warmup: 'Warm up', work: 'Run', recovery: 'Recover', cooldown: 'Cool down',
};

const MILE = 1609.344;

/** "0:50", "7:00", "1:02:03". */
export function lapClock(seconds: number): string {
  const total = Math.max(0, Math.floor(seconds));
  const h = Math.floor(total / 3600), m = Math.floor((total % 3600) / 60), s = total % 60;
  const ss = String(s).padStart(2, '0');
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

/** Seconds per km, or null under 10 m or without time. */
const perKm = (lap: RunLap) => lap.moving_s > 0 && lap.distance_m >= 10 ? lap.moving_s / (lap.distance_m / 1000) : null;

function distanceText(meters: number, miles: boolean): string {
  if (meters < 1000) return `${Math.round(meters)} m`;
  return `${(meters / (miles ? MILE : 1000)).toFixed(2)} ${miles ? 'mi' : 'km'}`;
}

function targetText(target: RunStepTarget, miles: boolean): string {
  if (target.type === 'pace') {
    const low = paceText(target.fastest_s_per_km, miles);
    const high = paceText(target.slowest_s_per_km, miles);
    return `Pace ${low === high ? low : `${low}–${high}`} /${miles ? 'mi' : 'km'}`;
  }
  const { min_bpm: low, max_bpm: high } = target;
  return `Heart rate ${low === high ? low : `${low}–${high}`} bpm`;
}

/** The lap's average pace or heart rate against the step's range. */
export function lapVerdict(lap: RunLap): LapVerdict | null {
  const target = lap.target;
  if (!target) return null;
  if (target.type === 'pace') {
    const pace = perKm(lap);
    if (pace === null) return null;
    const seconds = Math.round(pace);
    if (seconds < target.fastest_s_per_km) return 'fast';
    if (seconds > target.slowest_s_per_km) return 'slow';
    return 'on_target';
  }
  if (lap.avg_hr === null) return null;
  if (lap.avg_hr > target.max_bpm) return 'high';
  if (lap.avg_hr < target.min_bpm) return 'low';
  return 'on_target';
}

const VERDICT_WORDS: Record<LapVerdict, string> = {
  on_target: 'on target', fast: 'faster', slow: 'slower', high: 'above', low: 'below',
};

export function lapRows(laps: RunLap[] | null | undefined, miles: boolean): LapRow[] {
  return (laps ?? []).map((lap) => {
    let title = lap.kind ? KIND_TITLES[lap.kind] : 'After the plan';
    if (lap.round !== null && lap.rounds !== null) title += ` ${lap.round}/${lap.rounds}`;
    const note = lap.end === 'skipped' ? 'Skipped' : lap.end === 'stopped' && lap.step !== null ? 'Ended early' : null;
    const figures = [distanceText(lap.distance_m, miles), lapClock(lap.moving_s)];
    const pace = perKm(lap);
    const perUnit = pace === null ? null : pace * (miles ? MILE : 1000) / 1000;
    if (perUnit !== null && perUnit < 3600) {
      figures.push(`${lapClock(Math.round(perUnit))} /${miles ? 'mi' : 'km'}`);
    }
    if (lap.avg_hr !== null) figures.push(`${lap.avg_hr} bpm`);
    const verdict = lapVerdict(lap);
    const target = lap.target
      ? targetText(lap.target, miles) + (verdict ? ` · ${VERDICT_WORDS[verdict]}` : '')
      : null;
    return { kind: lap.kind, title, note, figures: figures.join(' · '), target, verdict };
  });
}
