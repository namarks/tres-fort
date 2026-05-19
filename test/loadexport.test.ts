import { describe, expect, it } from 'vitest';
import {
  computeSessionLoad,
  SRPE_LOAD_K,
  SRPE_FALLBACK_RPE,
  SRPE_MIN_MINUTES,
  SRPE_MAX_MINUTES,
} from '../src/db';

// A 60-minute session: started_at..completed_at exactly 1h apart unless a
// test overrides it.
const HOUR = 60 * 60_000;
const sess = (over: Partial<{ perceived_fatigue: number | null; started_at: number | null; completed_at: number | null }> = {}) => ({
  perceived_fatigue: null as number | null,
  started_at: 1_000_000,
  completed_at: 1_000_000 + HOUR,
  ...over,
});
const set = (over: Partial<{ weight: number; reps: number; rpe: number | null; is_warmup: number; deleted_at: number | null }> = {}) => ({
  weight: 100,
  reps: 5,
  rpe: 8 as number | null,
  is_warmup: 0,
  deleted_at: null as number | null,
  ...over,
});

describe('computeSessionLoad — pure sRPE truth table', () => {
  it('PRIORITY 1: perceived_fatigue wins over set RPE', () => {
    // 60 min, perceived_fatigue=9, sets have RPE 6 (ignored).
    const r = computeSessionLoad(sess({ perceived_fatigue: 9 }), [
      set({ rpe: 6 }),
      set({ rpe: 6 }),
    ]);
    expect(r).not.toBeNull();
    expect(r!.rpeSource).toBe('perceived_fatigue');
    expect(r!.sessionRpe).toBe(9);
    expect(r!.durationMin).toBe(60);
    expect(r!.load).toBe(Math.round(9 * 60 * SRPE_LOAD_K)); // 108
  });

  it('PRIORITY 2: load-weighted mean of non-warmup set RPE', () => {
    // Two sets: (100x5 @ RPE 8, vol 500) and (200x5 @ RPE 6, vol 1000).
    // weighted = (500*8 + 1000*6)/(1500) = 10000/1500 = 6.6667
    const r = computeSessionLoad(sess(), [
      set({ weight: 100, reps: 5, rpe: 8 }),
      set({ weight: 200, reps: 5, rpe: 6 }),
    ]);
    expect(r).not.toBeNull();
    expect(r!.rpeSource).toBe('weighted_set_rpe');
    expect(r!.sessionRpe).toBeCloseTo(10000 / 1500, 6);
    expect(r!.load).toBe(Math.round((10000 / 1500) * 60 * SRPE_LOAD_K)); // 80
  });

  it('PRIORITY 2: warmup sets are excluded from the weighted mean', () => {
    // Warmup RPE 2 must NOT drag the mean; only the working RPE 8 counts.
    const r = computeSessionLoad(sess(), [
      set({ rpe: 2, is_warmup: 1 }),
      set({ weight: 100, reps: 5, rpe: 8 }),
    ]);
    expect(r!.rpeSource).toBe('weighted_set_rpe');
    expect(r!.sessionRpe).toBe(8);
  });

  it('PRIORITY 3: fallback constant 7 when no perceived_fatigue and no set RPE', () => {
    const r = computeSessionLoad(sess(), [
      set({ rpe: null }),
      set({ rpe: null }),
    ]);
    expect(r).not.toBeNull();
    expect(r!.rpeSource).toBe('fallback');
    expect(r!.sessionRpe).toBe(SRPE_FALLBACK_RPE);
    expect(r!.load).toBe(Math.round(SRPE_FALLBACK_RPE * 60 * SRPE_LOAD_K)); // 84
  });

  it('duration clamp LOW: a 5-minute session is clamped up to 20 min', () => {
    const r = computeSessionLoad(
      sess({ perceived_fatigue: 8, started_at: 0, completed_at: 5 * 60_000 }),
      [set()],
    );
    expect(r!.durationMin).toBe(SRPE_MIN_MINUTES);
    expect(r!.load).toBe(Math.round(8 * SRPE_MIN_MINUTES * SRPE_LOAD_K)); // 32
  });

  it('duration clamp LOW: missing started/completed → floor 20 min', () => {
    const r = computeSessionLoad(
      sess({ perceived_fatigue: 8, started_at: null, completed_at: null }),
      [set()],
    );
    expect(r!.durationMin).toBe(SRPE_MIN_MINUTES);
  });

  it('duration clamp HIGH: a 5-hour session is clamped down to 180 min', () => {
    const r = computeSessionLoad(
      sess({ perceived_fatigue: 8, started_at: 0, completed_at: 5 * HOUR }),
      [set()],
    );
    expect(r!.durationMin).toBe(SRPE_MAX_MINUTES);
    expect(r!.load).toBe(Math.round(8 * SRPE_MAX_MINUTES * SRPE_LOAD_K)); // 288
  });

  it('SKIP: zero non-warmup sets → null (no export, NOT load 0)', () => {
    expect(computeSessionLoad(sess({ perceived_fatigue: 9 }), [])).toBeNull();
    expect(
      computeSessionLoad(sess({ perceived_fatigue: 9 }), [
        set({ is_warmup: 1 }),
        set({ is_warmup: 1 }),
      ]),
    ).toBeNull();
  });

  it('SKIP: only soft-deleted working sets → null', () => {
    expect(
      computeSessionLoad(sess(), [set({ deleted_at: 123 }), set({ deleted_at: 456 })]),
    ).toBeNull();
  });

  it('durationSec mirrors the clamped minutes for the activity payload', () => {
    const r = computeSessionLoad(sess({ perceived_fatigue: 7 }), [set()]);
    expect(r!.durationSec).toBe(60 * 60);
  });
});
