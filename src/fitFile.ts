// Minimal reader for Garmin FIT activity files
// (docs/plans/endurance-training-load P4). Pure: bytes in, a workout summary
// and its heart-rate and power samples out. It reads only what training load
// needs — file_id, session, activity and record messages — and skips every
// other message, developer field and unknown field by its declared size.
//
// Format: a 12- or 14-byte header (".FIT" at bytes 8–11, data size at 4–7),
// then records. A record header with bit 7 set is a compressed-timestamp data
// message; otherwise bit 6 marks a definition message (bit 5: it also defines
// developer fields) and bits 0–3 give the local message type. Several FIT
// files may be chained one after another.

import type { Sample } from './trainingLoad';

export class FitParseError extends Error {
  constructor(readonly code: 'not_fit' | 'truncated' | 'not_an_activity' | 'multisport' | 'no_data') {
    super(code);
  }
}

export interface FitActivity {
  /** Tres Fort activity kind (ride, run, swim, …), as kindOf and HealthKit use. */
  kind: string;
  start_utc_ms: number;
  /** Device clock offset from UTC in seconds, when the file records it. */
  local_offset_sec: number | null;
  elapsed_sec: number | null;
  /** Timer time: moving time, pauses excluded. */
  timer_sec: number | null;
  distance_m: number | null;
  calories: number | null;
  avg_hr: number | null;
  max_hr: number | null;
  avg_power: number | null;
  /** Normalized power the device computed, when it wrote one. */
  normalized_power: number | null;
  ascent_m: number | null;
  /** `t` is seconds from start_utc_ms. */
  hr: Sample[];
  power: Sample[];
}

/** Seconds between the Unix epoch and the FIT epoch (1989-12-31T00:00:00Z). */
const FIT_EPOCH_SEC = 631_065_600;

const MESG_FILE_ID = 0;
const MESG_SESSION = 18;
const MESG_RECORD = 20;
const MESG_ACTIVITY = 34;
const WANTED = new Set([MESG_FILE_ID, MESG_SESSION, MESG_RECORD, MESG_ACTIVITY]);
const FIELD_TIMESTAMP = 253;

interface FieldDef {
  num: number;
  size: number;
  baseType: number;
}

interface Definition {
  global: number;
  little: boolean;
  fields: FieldDef[];
  devSize: number;
  size: number;
}

type Fields = Map<number, number>;

/** Byte size of each base type (low five bits of the base-type byte). */
const BASE_SIZE = [1, 1, 1, 2, 2, 4, 4, 1, 4, 8, 1, 2, 4, 1, 8, 8, 8];

const CRC_TABLE = [
  0x0000, 0xcc01, 0xd801, 0x1400, 0xf001, 0x3c00, 0x2800, 0xe401,
  0xa001, 0x6c00, 0x7800, 0xb401, 0x5000, 0x9c01, 0x8801, 0x4400,
];

/** The FIT CRC-16 over bytes [from, to). */
export function fitCrc(bytes: Uint8Array, from = 0, to = bytes.length): number {
  let crc = 0;
  for (let i = from; i < to; i++) {
    const byte = bytes[i]!;
    let tmp = CRC_TABLE[crc & 0xf]!;
    crc = (crc >> 4) & 0x0fff;
    crc = crc ^ tmp ^ CRC_TABLE[byte & 0xf]!;
    tmp = CRC_TABLE[crc & 0xf]!;
    crc = (crc >> 4) & 0x0fff;
    crc = crc ^ tmp ^ CRC_TABLE[(byte >> 4) & 0xf]!;
  }
  return crc;
}

function readValue(view: DataView, at: number, field: FieldDef, little: boolean): number | null {
  const type = field.baseType & 0x1f;
  const size = BASE_SIZE[type];
  // Arrays and strings are never needed here; read only scalar fields.
  if (size === undefined || field.size !== size || type === 7) return null;
  switch (type) {
    case 0: case 2: case 13: { const v = view.getUint8(at); return v === 0xff ? null : v; }
    case 1: { const v = view.getInt8(at); return v === 0x7f ? null : v; }
    case 10: { const v = view.getUint8(at); return v === 0 ? null : v; }
    case 3: { const v = view.getInt16(at, little); return v === 0x7fff ? null : v; }
    case 4: { const v = view.getUint16(at, little); return v === 0xffff ? null : v; }
    case 11: { const v = view.getUint16(at, little); return v === 0 ? null : v; }
    case 5: { const v = view.getInt32(at, little); return v === 0x7fffffff ? null : v; }
    case 6: { const v = view.getUint32(at, little); return v === 0xffffffff ? null : v; }
    case 12: { const v = view.getUint32(at, little); return v === 0 ? null : v; }
    case 8: { const v = view.getFloat32(at, little); return Number.isFinite(v) ? v : null; }
    case 9: { const v = view.getFloat64(at, little); return Number.isFinite(v) ? v : null; }
    default: return null; // 64-bit integers: not used by any field read here
  }
}

/** FIT `sport` (and `sub_sport` for gym equipment) to a Tres Fort kind. */
export function fitKind(sport: number | null, subSport: number | null): string {
  switch (sport) {
    case 1: return 'run';
    case 2: return 'ride';
    case 5: return 'swim';
    case 11: return 'walk';
    case 17: return 'hike';
    case 15: return 'row';
    case 12: case 13: return 'ski';
    case 4: // fitness equipment
      if (subSport === 14) return 'row'; // indoor rowing
      if (subSport === 15) return 'elliptical';
      if (subSport === 1) return 'run'; // treadmill
      if (subSport === 6) return 'ride'; // indoor cycling
      return 'other';
    default: return 'other';
  }
}

export function parseFit(bytes: Uint8Array): FitActivity {
  const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
  const records: Fields[] = [];
  const sessions: Fields[] = [];
  let activity: Fields | null = null;
  let fileType: number | null = null;
  let sawHeader = false;

  let pos = 0;
  while (pos < bytes.length) {
    // Trailing padding after the last chained file is ignored.
    if (bytes.length - pos < 12) break;
    const headerSize = bytes[pos]!;
    if ((headerSize !== 12 && headerSize !== 14)
      || String.fromCharCode(bytes[pos + 8]!, bytes[pos + 9]!, bytes[pos + 10]!, bytes[pos + 11]!) !== '.FIT') {
      if (!sawHeader) throw new FitParseError('not_fit');
      break;
    }
    sawHeader = true;
    const dataSize = view.getUint32(pos + 4, true);
    const start = pos + headerSize;
    const end = start + dataSize;
    // Each file ends with a CRC over its header and data; a 14-byte header
    // also carries its own CRC, where zero means none was written. A file
    // that fails either check is damaged, and its values can't be trusted.
    if (end + 2 > bytes.length) throw new FitParseError('truncated');
    if (headerSize === 14) {
      const headerCrc = view.getUint16(pos + 12, true);
      if (headerCrc !== 0 && headerCrc !== fitCrc(bytes, pos, pos + 12)) throw new FitParseError('truncated');
    }
    if (view.getUint16(end, true) !== fitCrc(bytes, pos, end)) throw new FitParseError('truncated');
    const definitions = new Map<number, Definition>();
    let lastTimestamp: number | null = null;
    let at = start;
    while (at < end) {
      const header = bytes[at]!;
      at += 1;
      let local: number;
      let compressedOffset: number | null = null;
      if (header & 0x80) {
        local = (header >> 5) & 0x03;
        compressedOffset = header & 0x1f;
      } else if (header & 0x40) {
        // Definition message.
        if (at + 5 > end) throw new FitParseError('truncated');
        const little = bytes[at + 1] === 0;
        const global = view.getUint16(at + 2, little);
        const count = bytes[at + 4]!;
        at += 5;
        if (at + count * 3 > end) throw new FitParseError('truncated');
        const fields: FieldDef[] = [];
        let size = 0;
        for (let i = 0; i < count; i++) {
          const field = { num: bytes[at]!, size: bytes[at + 1]!, baseType: bytes[at + 2]! };
          fields.push(field);
          size += field.size;
          at += 3;
        }
        let devSize = 0;
        if (header & 0x20) {
          if (at + 1 > end) throw new FitParseError('truncated');
          const devCount = bytes[at]!;
          at += 1;
          if (at + devCount * 3 > end) throw new FitParseError('truncated');
          for (let i = 0; i < devCount; i++) {
            devSize += bytes[at + 1]!;
            at += 3;
          }
        }
        definitions.set(header & 0x0f, { global, little, fields, devSize, size: size + devSize });
        continue;
      } else {
        local = header & 0x0f;
      }
      const def = definitions.get(local);
      if (!def) throw new FitParseError('truncated');
      if (at + def.size > end) throw new FitParseError('truncated');
      {
        // Every message is read: a timestamp in any of them anchors the
        // compressed timestamps that follow.
        const values: Fields = new Map();
        let fieldAt = at;
        for (const field of def.fields) {
          const v = readValue(view, fieldAt, field, def.little);
          if (v !== null) values.set(field.num, v);
          fieldAt += field.size;
        }
        const stamped = values.get(FIELD_TIMESTAMP);
        if (stamped !== undefined) lastTimestamp = stamped;
        if (compressedOffset !== null && lastTimestamp !== null) {
          // The offset replaces the low five bits, rolling over forward.
          const low = lastTimestamp % 32;
          let ts: number = lastTimestamp - low + compressedOffset;
          if (compressedOffset < low) ts += 32;
          lastTimestamp = ts;
          values.set(FIELD_TIMESTAMP, ts);
        }
        if (!WANTED.has(def.global)) {
          at += def.size;
          continue;
        }
        if (def.global === MESG_RECORD) records.push(values);
        else if (def.global === MESG_SESSION) sessions.push(values);
        else if (def.global === MESG_ACTIVITY) activity = values;
        else if (def.global === MESG_FILE_ID && fileType === null) fileType = values.get(0) ?? null;
      }
      at += def.size;
    }
    pos = end + 2; // file CRC
  }

  if (fileType !== null && fileType !== 4) throw new FitParseError('not_an_activity');
  const sports = new Set(sessions.map(s => s.get(5) ?? null));
  if (sports.size > 1) throw new FitParseError('multisport');
  const session = sessions[0] ?? null;
  const stamps = records.map(r => r.get(FIELD_TIMESTAMP)).filter((v): v is number => v !== undefined);
  const firstStamp = stamps.length > 0 ? stamps.reduce((a, b) => Math.min(a, b)) : null;
  const lastStamp = stamps.length > 0 ? stamps.reduce((a, b) => Math.max(a, b)) : null;
  const startFit = session?.get(2) ?? firstStamp;
  if (startFit === null || startFit === undefined) throw new FitParseError('no_data');

  const sum = (key: number, scale = 1) => {
    if (sessions.length === 0) return null;
    let total = 0;
    for (const s of sessions) {
      const v = s.get(key);
      if (v === undefined) return null;
      total += v / scale;
    }
    return total;
  };
  const first = (key: number, scale = 1) => {
    const v = session?.get(key);
    return v === undefined ? null : v / scale;
  };

  const hr: Sample[] = [];
  const power: Sample[] = [];
  for (const r of records) {
    const ts = r.get(FIELD_TIMESTAMP);
    if (ts === undefined || ts < startFit) continue;
    const t = ts - startFit;
    const bpm = r.get(3);
    if (bpm !== undefined) hr.push({ t, v: bpm });
    const watts = r.get(7);
    if (watts !== undefined) power.push({ t, v: watts });
  }

  const recordSpan = firstStamp !== null && lastStamp !== null ? lastStamp - startFit : null;
  const elapsed = sum(7, 1000) ?? recordSpan;
  const timer = sum(8, 1000) ?? elapsed;
  const lastDistance = records.reduce<number | null>((d, r) => r.get(5) ?? d, null);
  const activityStamp = (activity as Fields | null)?.get(FIELD_TIMESTAMP);
  const activityLocal = (activity as Fields | null)?.get(5);
  const offset = activityStamp !== undefined && activityLocal !== undefined ? activityLocal - activityStamp : null;

  return {
    kind: fitKind(first(5), first(6)),
    start_utc_ms: (startFit + FIT_EPOCH_SEC) * 1000,
    // A real zone offset is within ±14 h; anything else is a bad clock.
    local_offset_sec: offset !== null && Math.abs(offset) <= 14 * 3600 ? offset : null,
    elapsed_sec: elapsed,
    timer_sec: timer,
    distance_m: sum(9, 100) ?? (lastDistance === null ? null : lastDistance / 100),
    calories: sum(11),
    avg_hr: first(16),
    max_hr: first(17),
    avg_power: first(20),
    normalized_power: first(34),
    ascent_m: sum(22),
    hr,
    power,
  };
}
