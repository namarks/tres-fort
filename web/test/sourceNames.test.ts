import { readdirSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { describe, expect, it } from 'vitest';

const root = fileURLToPath(new URL('..', import.meta.url));
const MODULE = /\.(ts|tsx|js|jsx|mjs|mts)$/;

function modules(dir: string): string[] {
  return readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) return modules(path);
    return MODULE.test(entry.name) ? [relative(root, path)] : [];
  });
}

describe('source file names', () => {
  // macOS disks ignore letter case, so `import './RouteMap'` can resolve to
  // routeMap.ts there while Linux CI finds RouteMap.tsx.
  it('never name two modules the same apart from letter case', () => {
    const byName = new Map<string, string[]>();
    for (const file of ['src', 'worker', 'test'].flatMap((dir) => modules(join(root, dir)))) {
      const key = file.replace(MODULE, '').toLowerCase();
      byName.set(key, [...(byName.get(key) ?? []), file]);
    }
    expect([...byName.values()].filter((files) => files.length > 1)).toEqual([]);
  });
});
