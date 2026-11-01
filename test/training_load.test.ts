import { describe, expect, it } from 'vitest';
import {
  averageHeartRateLoad,
  coveredSeconds,
  heartRateStreamLoad,
  normalizedPower,
  paceLoad,
  powerStreamLoad,
  powerSummaryLoad,
  selectLoad,
  type Sample,
} from '../src/trainingLoad';
import { thresholdOn, type AthleteThreshold } from '../src/services/athleteThresholds';

// Pure training-load engine (docs/plans/endurance-training-load P0). Every
// scale puts one hour at threshold at load 100 and intensity 100%.

const steady = (value: number, seconds: number, step = 1, from = 0): Sample[] =>
  Array.from({ length: Math.round(seconds / step) }, (_, i) => ({ t: from + i * step, v: value }));

describe('normalized power', () => {
  it('equals the power of a steady effort', () => {
    expect(normalizedPower(steady(200, 3600))).toBeCloseTo(200, 6);
  });

  it('weights hard efforts above the average', () => {
    const samples = [...steady(300, 1800), ...steady(100, 1800, 1, 1800)];
    // Hand-computed: 1771 windows at 300 W, 1771 at 100 W and 29 transition
    // windows stepping down by 200/30 W each.
    let sum4 = 1771 * 300 ** 4 + 1771 * 100 ** 4;
    for (let k = 1; k <= 29; k++) sum4 += (300 - (200 * k) / 30) ** 4;
    const expected = (sum4 / 3571) ** 0.25;
    expect(normalizedPower(samples)).toBeCloseTo(expected, 6);
    expect(expected).toBeGreaterThan(250); // well above the 200 W average
  });

  it('does not fill a recording pause', () => {
    const samples = [...steady(200, 600), ...steady(200, 600, 1, 660)];
    expect(coveredSeconds(samples)).toBe(1200);
    expect(normalizedPower(samples)).toBeCloseTo(200, 6);
  });

  it('needs at least 30 continuous seconds', () => {
    expect(normalizedPower(steady(200, 20))).toBeNull();
  });
});

describe('power load', () => {
  it('scores one hour at FTP as 100', () => {
    expect(powerStreamLoad(steady(250, 3600), 3600, 250)).toEqual({ load: 100, intensity: 100, method: 'power' });
  });

  it('matches intervals.icu for a real Zwift ride summary', () => {
    // Sep 4, 2026 "10/8/4min Threshold": NP 198 W, 3446 s moving; intervals.icu
    // reported load 72 and intensity 86.46, which implies an FTP of 229 W.
    expect(powerSummaryLoad(198, 3446, 229)).toEqual({ load: 72, intensity: 86.5, method: 'power_summary' });
  });

  it('refuses a stream that covers too little of the workout', () => {
    expect(powerStreamLoad(steady(250, 1200), 3600, 250)).toBeNull();
  });
});

describe('heart-rate load', () => {
  it('scores one hour at threshold heart rate as 100', () => {
    expect(heartRateStreamLoad(steady(160, 3600), 3600, 160)).toEqual({ load: 100, intensity: 100, method: 'heart_rate' });
  });

  it('integrates twice-a-second samples by time', () => {
    // 30 minutes at 90% of threshold: 0.5 h × 0.81 × 100 = 40.5 (plus the
    // final half-second sample's extra hold).
    const r = heartRateStreamLoad(steady(144, 1800, 0.5), 1800, 160);
    expect(r).toEqual({ load: 41, intensity: 90, method: 'heart_rate' });
  });

  it('treats zero heart rate as a dropout, not a reading', () => {
    expect(heartRateStreamLoad(steady(0, 3600), 3600, 160)).toBeNull();
    expect(selectLoad({ moving_time_sec: 3600, distance_m: 10000, hr_samples: steady(0, 3600) }, { threshold_hr: 160, threshold_pace_s_per_km: 300 })?.method)
      .toBe('pace');
    // A five-minute dropout inside an hour at threshold leaves a gap rather
    // than five minutes of zero load.
    const withDropout = steady(160, 3600).map(s => (s.t >= 1800 && s.t < 2100 ? { ...s, v: 0 } : s));
    expect(heartRateStreamLoad(withDropout, 3300, 160)).toEqual({ load: 92, intensity: 100, method: 'heart_rate' });
  });

  it('refuses Zwift-style samples every ten minutes', () => {
    expect(heartRateStreamLoad(steady(140, 3600, 600), 3600, 160)).toBeNull();
  });

  it('matches intervals.icu from average heart rate on a real Garmin run', () => {
    // Aug 27, 2026: average HR 154 for 1920 s; intervals.icu reported load 45
    // and intensity 91.83, which implies a threshold heart rate near 167.7.
    expect(averageHeartRateLoad(154, 1920, 167.7)).toEqual({ load: 45, intensity: 91.8, method: 'heart_rate_average' });
  });
});

describe('pace load', () => {
  it('scores a run against threshold pace', () => {
    // 10 km in 60 minutes (6:00/km) at a 5:00/km threshold: (300/360)² × 100.
    expect(paceLoad(10000, 3600, 300)).toEqual({ load: 69, intensity: 83.3, method: 'pace' });
  });

  it('needs distance, time and a threshold', () => {
    expect(paceLoad(null, 3600, 300)).toBeNull();
    expect(paceLoad(10000, 0, 300)).toBeNull();
    expect(paceLoad(10000, 3600, null)).toBeNull();
  });
});

describe('selectLoad', () => {
  const all = { ftp_w: 250, threshold_hr: 160, threshold_pace_s_per_km: 300 };

  it("prefers the provider's own load", () => {
    expect(selectLoad({ moving_time_sec: 3446, provider_load: 72, provider_intensity: 86.46288, weighted_avg_watts: 198 }, all))
      .toEqual({ load: 72, intensity: 86.5, method: 'provider' });
  });

  it('prefers power, then heart rate, then pace, then average heart rate', () => {
    const base = { moving_time_sec: 3600, distance_m: 10000, average_hr: 150 };
    expect(selectLoad({ ...base, power_samples: steady(250, 3600), hr_samples: steady(160, 3600) }, all)?.method).toBe('power');
    expect(selectLoad({ ...base, weighted_avg_watts: 250, hr_samples: steady(160, 3600) }, all)?.method).toBe('power_summary');
    expect(selectLoad({ ...base, hr_samples: steady(160, 3600) }, all)?.method).toBe('heart_rate');
    expect(selectLoad({ ...base, hr_samples: steady(160, 3600, 600) }, all)?.method).toBe('pace');
    expect(selectLoad({ moving_time_sec: 3600, average_hr: 150 }, all)?.method).toBe('heart_rate_average');
  });

  it('skips a method whose threshold is not set', () => {
    const r = selectLoad({ moving_time_sec: 3600, power_samples: steady(250, 3600), hr_samples: steady(160, 3600) }, { threshold_hr: 160 });
    expect(r?.method).toBe('heart_rate');
  });

  it('returns null rather than zero when nothing is usable', () => {
    expect(selectLoad({ moving_time_sec: 3600, distance_m: 10000, average_hr: 150 }, {})).toBeNull();
    expect(selectLoad({ moving_time_sec: null, average_hr: 150 }, all)).toBeNull();
  });
});

describe('thresholdOn', () => {
  const row = (value: number, effective_date: string, created_at = 1): AthleteThreshold => ({
    id: crypto.randomUUID(), sport: 'ride', metric: 'ftp_w', value, effective_date, source: 'member', created_at,
  });
  const rows = [row(260, '2026-09-01'), row(250, '2026-06-01'), row(270, '2026-09-01', 2)];

  it('uses the latest row on or before the date, newest on a tie', () => {
    expect(thresholdOn(rows, 'ride', 'ftp_w', '2026-07-01')).toBe(250);
    expect(thresholdOn(rows, 'ride', 'ftp_w', '2026-09-01')).toBe(270);
  });

  it('applies the earliest row to older dates', () => {
    expect(thresholdOn(rows, 'ride', 'ftp_w', '2026-01-01')).toBe(250);
  });

  it('is null for a metric with no rows', () => {
    expect(thresholdOn(rows, 'run', 'threshold_hr', '2026-07-01')).toBeNull();
  });
});
