import { describe, expect, it } from 'vitest';
import {
  distanceDisplay,
  draftFromRunSteps,
  moved,
  newRepeat,
  newStep,
  paceText,
  parseDuration,
  parsePace,
  runStepsFromDraft,
  sameRunSteps,
  stepFromDraft,
  type ItemDraft,
} from '../src/runPlan';

const single = (step = newStep(false)): ItemDraft => ({ id: crypto.randomUUID(), repeats: null, steps: [step] });

describe('reading what the member types', () => {
  it('reads times as minutes and seconds, hours, or whole minutes', () => {
    expect(parseDuration('10:00')).toBe(600);
    expect(parseDuration('1:30')).toBe(90);
    expect(parseDuration('1:05:00')).toBe(3900);
    expect(parseDuration('12')).toBe(720);
    expect(parseDuration('1:5')).toBeNull();
    expect(parseDuration('ten')).toBeNull();
  });

  it('reads paces as minutes and seconds', () => {
    expect(parsePace('4:05')).toBe(245);
    expect(parsePace('12:00')).toBe(720);
    expect(parsePace('4:5')).toBeNull();
    expect(parsePace('4:60')).toBeNull();
  });

  it('shows distances and paces as the app does', () => {
    expect(distanceDisplay(800, true)).toEqual({ unit: 'm', text: '800' });
    expect(distanceDisplay(5000, false)).toEqual({ unit: 'km', text: '5' });
    expect(distanceDisplay(1609.344, true)).toEqual({ unit: 'mi', text: '1' });
    expect(paceText(300, false)).toBe('5:00');
    expect(paceText(300, true)).toBe('8:03');
  });
});

describe('one step', () => {
  it('stores a time or a distance, and a pace or heart rate range', () => {
    expect(stepFromDraft({ ...newStep(false), kind: 'warmup', time: '10:00' }, false))
      .toEqual({ ok: true, step: { kind: 'warmup', duration_s: 600 } });
    expect(stepFromDraft({ ...newStep(false), ends: 'distance', distance: '800', unit: 'm', target: 'pace', fastest: '3:50', slowest: '4:00' }, false))
      .toEqual({ ok: true, step: { kind: 'work', distance_m: 800, target: { type: 'pace', fastest_s_per_km: 230, slowest_s_per_km: 240 } } });
    expect(stepFromDraft({ ...newStep(true), target: 'pace', fastest: '6:00', slowest: '6:15' }, true))
      .toEqual({ ok: true, step: { kind: 'work', duration_s: 600, target: { type: 'pace', fastest_s_per_km: 224, slowest_s_per_km: 233 } } });
    expect(stepFromDraft({ ...newStep(false), target: 'heart_rate', low: '140', high: '150' }, false))
      .toEqual({ ok: true, step: { kind: 'work', duration_s: 600, target: { type: 'heart_rate', min_bpm: 140, max_bpm: 150 } } });
  });

  it('explains what the Worker would refuse', () => {
    const error = (patch: Parameters<typeof stepFromDraft>[0]) => {
      const result = stepFromDraft(patch, false);
      return result.ok ? null : result.error;
    };
    expect(error({ ...newStep(false), time: '0:00' })).toMatch(/Enter a time/);
    expect(error({ ...newStep(false), time: '6:00:01' })).toBe('A step can be at most 6 hours.');
    expect(error({ ...newStep(false), ends: 'distance', distance: '101', unit: 'km' })).toBe('A step can be at most 100 km.');
    expect(error({ ...newStep(false), ends: 'distance', distance: 'far' })).toMatch(/Enter a distance/);
    expect(error({ ...newStep(false), target: 'pace', fastest: '4:30', slowest: '4:00' })).toMatch(/fast end/);
    expect(error({ ...newStep(false), target: 'pace', fastest: '1:00', slowest: '4:00' })).toMatch(/between 2:00 and 20:00/);
    expect(error({ ...newStep(false), target: 'heart_rate', low: '160', high: '150' })).toMatch(/low end/);
    expect(error({ ...newStep(false), target: 'heart_rate', low: '20', high: '150' })).toMatch(/between 40 and 230/);
  });
});

describe('a whole plan', () => {
  it('saves steps and repeats in order, and no steps as none', () => {
    const warmup = single({ ...newStep(false), kind: 'warmup' });
    expect(runStepsFromDraft([warmup, newRepeat(false)], false)).toEqual({
      ok: true,
      items: [
        { kind: 'warmup', duration_s: 600 },
        { repeat: 4, steps: [{ kind: 'work', duration_s: 180 }, { kind: 'recovery', duration_s: 90 }] },
      ],
    });
    expect(runStepsFromDraft([], false)).toEqual({ ok: true, items: null });
  });

  it('names the part with a problem and checks the repeat limits', () => {
    const repeat = { ...newRepeat(false), repeats: '0' };
    repeat.steps[1] = { ...repeat.steps[1]!, time: 'soon' };
    const result = runStepsFromDraft([single(), repeat], false);
    expect(result).toEqual({
      ok: false,
      errors: [
        'Repeat 2, step 2: Enter a time, such as 10:00 or 1:05:00.',
        'Repeat 2: a repeat runs 1 to 50 times.',
      ],
    });
    const many = { ...newRepeat(false), repeats: '50' };
    many.steps = [...many.steps, ...many.steps.map((step) => ({ ...step, id: crypto.randomUUID() }))];
    expect(runStepsFromDraft([many], false).ok).toBe(true);
    expect(runStepsFromDraft([single(), many], false)).toEqual({ ok: false, errors: ['With repeats, a plan can have at most 200 steps.'] });
  });

  it('reads stored steps back exactly, even where the text is rounded', () => {
    const stored = JSON.stringify([
      { kind: 'warmup', distance_m: 1234.5 },
      { repeat: 3, steps: [{ kind: 'work', duration_s: 95, target: { type: 'pace', fastest_s_per_km: 301, slowest_s_per_km: 302 } }] },
      { kind: 'cooldown', duration_s: 600, target: { type: 'heart_rate', min_bpm: 120, max_bpm: 140 } },
    ]);
    const draft = draftFromRunSteps(stored, true)!;
    expect(draft[0]!.steps[0]).toMatchObject({ ends: 'distance', distance: '0.77', unit: 'mi' });
    expect(draft[1]!.steps[0]).toMatchObject({ time: '1:35', fastest: '8:04', slowest: '8:06' });
    const result = runStepsFromDraft(draft, true);
    expect(result.ok && sameRunSteps(stored, result.items)).toBe(true);

    // Changing the text uses the new value.
    draft[0]!.steps[0] = { ...draft[0]!.steps[0]!, distance: '1' };
    const changed = runStepsFromDraft(draft, true);
    expect(changed.ok && changed.items?.[0]).toEqual({ kind: 'warmup', distance_m: 1609.344 });
    expect(changed.ok && sameRunSteps(stored, changed.items)).toBe(false);
  });

  it('offers only removal for steps it cannot read', () => {
    expect(draftFromRunSteps(null, false)).toEqual([]);
    expect(draftFromRunSteps('[{"kind":"sprint","duration_s":10}]', false)).toBeNull();
    expect(sameRunSteps(null, null)).toBe(true);
  });

  it('moves a part one place and stops at the ends', () => {
    const list = [{ id: 'a' }, { id: 'b' }, { id: 'c' }];
    expect(moved(list, 'b', -1).map((entry) => entry.id)).toEqual(['b', 'a', 'c']);
    expect(moved(list, 'c', 1).map((entry) => entry.id)).toEqual(['a', 'b', 'c']);
  });
});
