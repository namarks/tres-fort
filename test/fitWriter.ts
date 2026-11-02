import { fitCrc } from '../src/fitFile';

// Builds FIT files for tests (src/fitFile.ts reads them). Supports exactly
// what the reader handles: definitions in either byte order, developer
// fields, normal and compressed-timestamp data messages, chained files.

export type FitType = 'enum' | 'uint8' | 'uint16' | 'uint32' | 'sint32';

const TYPES: Record<FitType, { code: number; size: number; invalid: number }> = {
  enum: { code: 0x00, size: 1, invalid: 0xff },
  uint8: { code: 0x02, size: 1, invalid: 0xff },
  uint16: { code: 0x84, size: 2, invalid: 0xffff },
  uint32: { code: 0x86, size: 4, invalid: 0xffffffff },
  sint32: { code: 0x85, size: 4, invalid: 0x7fffffff },
};

export const FIT_EPOCH_SEC = 631_065_600;
export const fitTime = (iso: string) => Date.parse(iso) / 1000 - FIT_EPOCH_SEC;

interface Def {
  fields: { num: number; type: FitType }[];
  devSizes: number[];
  little: boolean;
}

export class FitWriter {
  private body: number[] = [];
  private defs = new Map<number, Def>();
  private files: number[][] = [];

  define(local: number, global: number, fields: { num: number; type: FitType }[],
         opts: { devSizes?: number[]; bigEndian?: boolean } = {}): this {
    const devSizes = opts.devSizes ?? [];
    const little = !opts.bigEndian;
    this.body.push(0x40 | (devSizes.length > 0 ? 0x20 : 0) | local, 0, little ? 0 : 1);
    this.body.push(...(little ? [global & 0xff, global >> 8] : [global >> 8, global & 0xff]));
    this.body.push(fields.length);
    for (const f of fields) this.body.push(f.num, TYPES[f.type].size, TYPES[f.type].code);
    if (devSizes.length > 0) {
      this.body.push(devSizes.length);
      devSizes.forEach((size, i) => this.body.push(i, size, 0));
    }
    this.defs.set(local, { fields, devSizes, little });
    return this;
  }

  data(local: number, values: (number | null)[]): this {
    this.body.push(local);
    return this.values(local, values);
  }

  /** A compressed-timestamp data message (local types 0–3). */
  compressed(local: number, offset: number, values: (number | null)[]): this {
    this.body.push(0x80 | (local << 5) | (offset & 0x1f));
    return this.values(local, values);
  }

  private values(local: number, values: (number | null)[]): this {
    const def = this.defs.get(local);
    if (!def) throw new Error(`no definition for ${local}`);
    def.fields.forEach((f, i) => {
      const { size, invalid } = TYPES[f.type];
      const raw = values[i] ?? invalid;
      const v = raw < 0 ? raw + 2 ** (size * 8) : raw;
      const bytes = Array.from({ length: size }, (_, b) => Math.floor(v / 2 ** (8 * b)) & 0xff);
      this.body.push(...(def.little ? bytes : bytes.reverse()));
    });
    for (const size of def.devSizes) this.body.push(...new Array(size).fill(0xab));
    return this;
  }

  /** Close the current file and start a chained one. */
  chain(): this {
    this.files.push(this.body);
    this.body = [];
    this.defs.clear();
    return this;
  }

  bytes(): Uint8Array {
    const out: number[] = [];
    for (const body of [...this.files, this.body]) {
      const size = body.length;
      const header = [14, 0x20, 0x08, 0x08, size & 0xff, (size >> 8) & 0xff, (size >> 16) & 0xff, (size >>> 24) & 0xff,
        0x2e, 0x46, 0x49, 0x54];
      const headerCrc = fitCrc(new Uint8Array(header));
      const file = [...header, headerCrc & 0xff, headerCrc >> 8, ...body];
      const crc = fitCrc(new Uint8Array(file));
      out.push(...file, crc & 0xff, crc >> 8);
    }
    return new Uint8Array(out);
  }
}

/** A single-sport activity: one record per `step` seconds. */
export function activityFit(opts: {
  start: string;
  seconds: number;
  sport?: number;
  hr?: number | null;
  power?: number | null;
  step?: number;
  localOffsetSec?: number | null;
  distanceM?: number;
  normalizedPower?: number | null;
}): Uint8Array {
  const start = fitTime(opts.start);
  const step = opts.step ?? 1;
  const w = new FitWriter()
    .define(0, 0, [{ num: 0, type: 'enum' }, { num: 4, type: 'uint32' }])
    .data(0, [4, start])
    .define(1, 20, [
      { num: 253, type: 'uint32' }, { num: 3, type: 'uint8' }, { num: 7, type: 'uint16' }, { num: 5, type: 'uint32' },
    ]);
  for (let t = 0; t < opts.seconds; t += step) {
    w.data(1, [start + t, opts.hr ?? null, opts.power ?? null, Math.round(((opts.distanceM ?? 0) * t / opts.seconds) * 100)]);
  }
  w.define(2, 18, [
    { num: 253, type: 'uint32' }, { num: 2, type: 'uint32' }, { num: 5, type: 'enum' }, { num: 6, type: 'enum' },
    { num: 7, type: 'uint32' }, { num: 8, type: 'uint32' }, { num: 9, type: 'uint32' }, { num: 11, type: 'uint16' },
    { num: 16, type: 'uint8' }, { num: 17, type: 'uint8' }, { num: 20, type: 'uint16' }, { num: 34, type: 'uint16' },
    { num: 22, type: 'uint16' },
  ]).data(2, [
    start + opts.seconds, start, opts.sport ?? 2, 0, opts.seconds * 1000, opts.seconds * 1000,
    Math.round((opts.distanceM ?? 0) * 100), 600, opts.hr ?? null, opts.hr === null || opts.hr === undefined ? null : opts.hr + 10,
    opts.power ?? null, opts.normalizedPower ?? null, 120,
  ]);
  const end = start + opts.seconds;
  if (opts.localOffsetSec === null) {
    w.define(3, 34, [{ num: 253, type: 'uint32' }]).data(3, [end]);
  } else {
    w.define(3, 34, [{ num: 253, type: 'uint32' }, { num: 5, type: 'uint32' }])
      .data(3, [end, end + (opts.localOffsetSec ?? -7 * 3600)]);
  }
  return w.bytes();
}
