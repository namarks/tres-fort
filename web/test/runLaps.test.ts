import { describe, expect, it } from 'vitest';
import { lapClock, lapRows, lapVerdict, type RunLap } from '../src/runLaps';

const lap = (fields: Partial<RunLap>): RunLap => ({
  step: 2, kind: 'work', round: 1, rounds: 4, planned_duration_s: null, planned_distance_m: 200,
  target: { type: 'pace', fastest_s_per_km: 230, slowest_s_per_km: 240 },
  start_s: 60, moving_s: 50, distance_m: 200, avg_hr: 170, max_hr: 176, end: 'completed', ...fields,
});

describe('planned run laps on the web', () => {
  it('reads each lap the way the app does, against its target', () => {
    const rows = lapRows([
      lap({}),
      lap({ step: 3, kind: 'recovery', planned_duration_s: 30, planned_distance_m: null,
        target: { type: 'heart_rate', min_bpm: 140, max_bpm: 150 }, moving_s: 30, distance_m: 60, avg_hr: 152,
        end: 'skipped' }),
      lap({ step: 9, kind: 'cooldown', round: null, rounds: null, target: null, moving_s: 420, distance_m: 1200,
        avg_hr: null, max_hr: null, end: 'stopped' }),
      lap({ step: null, kind: null, round: null, rounds: null, planned_distance_m: null, target: null,
        moving_s: 60, distance_m: 60, avg_hr: 110, end: 'stopped' }),
    ], true);
    expect(rows.map((r) => r.title)).toEqual(['Run 1/4', 'Recover 1/4', 'Cool down', 'After the plan']);
    expect(rows.map((r) => r.note)).toEqual([null, 'Skipped', 'Ended early', null]);
    expect(rows[0]).toMatchObject({
      figures: '200 m · 0:50 · 6:42 /mi · 170 bpm', target: 'Pace 6:10–6:26 /mi · slower', verdict: 'slow',
    });
    expect(rows[1]).toMatchObject({ target: 'Heart rate 140–150 bpm · above', verdict: 'high' });
    expect(rows[2]).toMatchObject({ figures: '0.75 mi · 7:00 · 9:23 /mi', target: null });
    expect(rows[3]!.figures).toBe('60 m · 1:00 · 26:49 /mi · 110 bpm');
    expect(lapRows([lap({ moving_s: 420, distance_m: 1200 })], false)[0]!.figures).toBe('1.20 km · 7:00 · 5:50 /km · 170 bpm');
    expect(lapRows(null, true)).toEqual([]);
  });

  it('judges pace to the whole second the target is written in', () => {
    expect(lapVerdict(lap({ moving_s: 94, distance_m: 400 }))).toBe('on_target');
    expect(lapVerdict(lap({ moving_s: 88, distance_m: 400 }))).toBe('fast');
    expect(lapVerdict(lap({ distance_m: 5 }))).toBeNull();
    expect(lapVerdict(lap({ target: { type: 'heart_rate', min_bpm: 150, max_bpm: 160 }, avg_hr: 145 }))).toBe('low');
    expect(lapVerdict(lap({ target: { type: 'heart_rate', min_bpm: 150, max_bpm: 160 }, avg_hr: null }))).toBeNull();
    expect(lapClock(3723)).toBe('1:02:03');
  });
});
