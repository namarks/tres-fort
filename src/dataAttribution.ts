/** Attribution travels with Intervals imports through UI, exports and MCP. */
export const GARMIN_SUMMARY_ATTRIBUTION = 'Includes Garmin device-sourced data';
export const ATTRIBUTION_INSTRUCTIONS = 'Preserve source_attribution when displaying or exporting activities. Attribute summaries and recommendations derived from Garmin data to Garmin; retain the device model for individual activities when supplied.';

export function activitySourceAttribution(activity: { source?: unknown; raw?: unknown }): string | null {
  if (activity.source !== 'intervals' || typeof activity.raw !== 'string') return null;
  let device: unknown;
  try { device = JSON.parse(activity.raw)?.device_name; } catch { return null; }
  if (typeof device !== 'string') return null;
  const index = device.toLowerCase().indexOf('garmin');
  if (index < 0) return null;
  // Device metadata is untrusted. Export only a bounded, single-line model
  // label, never arbitrary provider JSON or control/markup characters.
  const suffix = device.slice(index + 6);
  if (/[\r\n\t\u0000-\u001f]/.test(suffix)) return 'Garmin';
  const model = suffix.trim();
  return model && model.length <= 80 && /^[\p{L}\p{N} .()+/®™_-]+$/u.test(model)
    ? `Garmin ${model}` : 'Garmin';
}

export function withActivityAttribution<T extends { source?: unknown; raw?: unknown }>(activity: T) {
  return { ...activity, source_attribution: activitySourceAttribution(activity), attribution_version: 1 };
}

/** Only call with static SQL column expressions, never request input. */
export function deviceNameSQL(raw: string): string {
  return `(CASE WHEN json_valid(${raw}) THEN CASE WHEN json_type(${raw}, '$.device_name') = 'text' THEN json_extract(${raw}, '$.device_name') END END)`;
}

// Aggregate only provenance inside existing visibility/date predicates.
export const GARMIN_ACTIVITY_SQL = `(source = 'intervals' AND instr(lower(${deviceNameSQL('raw')}), 'garmin') > 0)`;
