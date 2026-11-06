// Heart-rate series Tres Fort keeps for a member's own runs
// (docs/plans/run-detail-charts P3, migration 0068): a run recorded in the
// app, and an Apple Health run, so their charts have heart rate like an
// intervals.icu run's. Pure: no D1. Readings are kept one per whole second
// of moving time (pauses already taken out by the source), as small
// integers delta-coded in JSON text, so a long run stays far below D1's
// 2 MB row limit.

import type { Sample } from './trainingLoad';

/**
 * The stored and exported form. Reading i is at `sum(dt[0..i])` seconds of
 * moving time from `start_ms`, so `dt[0]` is the first reading's own time;
 * `bpm[i]` is its whole beats a minute. `start_ms` is the epoch millisecond
 * the clock starts at (the workout's start, or a recording's first point),
 * so the series lines up with a route that starts at its first GPS fix;
 * null when the source didn't say.
 */
export interface EncodedHeartRate {
  v: 1;
  start_ms: number | null;
  dt: number[];
  bpm: number[];
}

/** A day at one reading a second, the most an Apple Health push carries. */
export const MAX_HEART_RATE_POINTS = 86_400;
/** Readings outside this range are a strap's noise, not a heart. */
export const MIN_BPM = 25;
export const MAX_BPM = 250;

/**
 * Encode readings on a moving-time clock (seconds from the start, pauses
 * taken out). Readings in the same whole second are averaged; invalid ones
 * are dropped. Null when none is left.
 */
export function encodeHeartRate(samples: readonly Sample[], startMs: number | null): EncodedHeartRate | null {
  const sums = new Map<number, { s: number; n: number }>();
  for (const { t, v } of samples) {
    if (!Number.isFinite(t) || t < 0 || !Number.isFinite(v) || v < MIN_BPM || v > MAX_BPM) continue;
    const second = Math.floor(t);
    if (second >= MAX_HEART_RATE_POINTS) continue;
    const bucket = sums.get(second);
    if (bucket) {
      bucket.s += v;
      bucket.n += 1;
    } else {
      sums.set(second, { s: v, n: 1 });
    }
  }
  if (sums.size === 0) return null;
  const seconds = [...sums.keys()].sort((a, b) => a - b);
  const out: EncodedHeartRate = {
    v: 1, start_ms: startMs !== null && Number.isSafeInteger(startMs) ? startMs : null, dt: [], bpm: [],
  };
  let last = 0;
  for (const second of seconds) {
    const { s, n } = sums.get(second)!;
    out.dt.push(second - last);
    out.bpm.push(Math.round(s / n));
    last = second;
  }
  return out;
}

/** The readings back, in moving seconds from the start. */
export function decodeHeartRate(series: EncodedHeartRate): Sample[] {
  const out: Sample[] = [];
  let t = 0;
  for (let i = 0; i < series.dt.length; i++) {
    t += series.dt[i]!;
    out.push({ t, v: series.bpm[i]! });
  }
  return out;
}

const isIntArray = (a: unknown, ok: (n: number) => boolean): a is number[] =>
  Array.isArray(a) && a.every((n) => Number.isSafeInteger(n) && ok(n as number));

/** A stored series, or null when the text isn't one. */
export function parseStoredHeartRate(text: string): EncodedHeartRate | null {
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return null;
  }
  if (typeof value !== 'object' || value === null) return null;
  const { v, start_ms: start, dt, bpm } = value as Record<string, unknown>;
  if (v !== 1 || !isIntArray(dt, (n) => n >= 0) || !isIntArray(bpm, (n) => n >= MIN_BPM && n <= MAX_BPM)) return null;
  if (dt.length === 0 || dt.length !== bpm.length) return null;
  if (start !== undefined && start !== null && !Number.isSafeInteger(start)) return null;
  return { v: 1, start_ms: typeof start === 'number' ? start : null, dt, bpm };
}
