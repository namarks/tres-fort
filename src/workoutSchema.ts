/** Temporary release-A/B bridge. Service SQL uses workout names throughout;
 * only this boundary knows the pre-rename physical identifiers. Remove it in
 * release C after migration and the released-client compatibility window. */
type Schema = 'legacy' | 'workouts';
type Database = Pick<D1Database, 'prepare' | 'batch'>;
const schemaCache = new WeakMap<Database, { schema: Schema; checkedAt: number }>();
const cacheRoots = new WeakMap<Database, Database>();

/** Request-local observers share only schema metadata with the underlying
 * binding. Probes still execute on the observing request and are measured. */
export function shareWorkoutSchemaCache(wrapper: Database, underlying: Database): void {
  cacheRoots.set(wrapper, cacheRoots.get(underlying) ?? underlying);
}

const databases = new WeakMap<D1Database, D1Database>();
const statements = new WeakMap<D1PreparedStatement, { query: string; values: unknown[]; db: Database }>();

const legacyIdentifiers: Readonly<Record<string, string>> = {
  workouts: 'day_templates', workout_id: 'day_template_id', ix_te_workout: 'ix_te_day',
};

// execute() calls this once per statement execution purely to decide whether a
// query is schema-adaptive, so the same handful of service SQL strings are
// re-tokenised on every request. The rewrite is a pure function of (query,
// mode), so memoise it. Keyed by mode too, so a future mode cannot collide.
// Bounded and insertion-ordered: on overflow the oldest entry is dropped.
const REWRITE_CACHE_LIMIT = 1024;
const rewriteCache = new Map<string, string>();

/** Rewrite SQL identifiers, never text literals, bound values or comments.
 * In particular json_object('workout_id', ...) must retain its canonical key. */
export function workoutSchemaSQL(query: string, schema: Schema): string {
  if (schema === 'workouts') return query;
  const key = `${schema}\u0000${query}`;
  const hit = rewriteCache.get(key);
  if (hit !== undefined) return hit;
  const rewritten = rewriteLegacySQL(query);
  if (rewriteCache.size >= REWRITE_CACHE_LIMIT) {
    const oldest = rewriteCache.keys().next();
    if (!oldest.done) rewriteCache.delete(oldest.value);
  }
  rewriteCache.set(key, rewritten);
  return rewritten;
}

function rewriteLegacySQL(query: string): string {
  return query.replace(
    /'(?:''|[^'])*'|--[^\n]*|\/\*[\s\S]*?\*\/|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*/g,
    (token) => {
      const first = token[0];
      if (first === "'" || token.startsWith('--') || token.startsWith('/*')) return token;
      const quoted = first === '"' || first === '`' || first === '[';
      const identifier = quoted ? token.slice(1, -1) : token;
      const replacement = legacyIdentifiers[identifier.toLowerCase()];
      return replacement ? (quoted ? first + replacement + token.slice(-1) : replacement) : token;
    },
  );
}

function canonicalColumn(name: string): string {
  return name === 'day_template_id' ? 'workout_id' : name;
}

/** SELECT * returns physical keys. Do not recursively rewrite historical JSON,
 * user text or audit data; those have their own explicit wire/snapshot readers. */
function canonicalRow<T>(row: T): T {
  if (!row || typeof row !== 'object' || !Object.hasOwn(row, 'day_template_id')) return row;
  return Object.fromEntries(Object.entries(row).map(([key, value]) => [canonicalColumn(key), value])) as T;
}

function canonicalResult<T>(result: D1Result<T>): D1Result<T> {
  return { ...result, results: result.results.map(canonicalRow) };
}

async function schemaFor(db: Database, force = false): Promise<Schema> {
  const cached = schemaCache.get(cacheRoots.get(db) ?? db);
  if (!force && cached && Date.now() - cached.checkedAt < 60_000) return cached.schema;
  // No request promises or prepared statements are shared between requests.
  const columns = await db.prepare('PRAGMA table_info(sessions)').all<{ name: string }>();
  const names = new Set(columns.results.map((column) => column.name));
  const schema = names.has('workout_id') ? 'workouts' : names.has('day_template_id') ? 'legacy' : null;
  if (!schema) throw new Error('unsupported_workout_schema');
  schemaCache.set(cacheRoots.get(db) ?? db, { schema, checkedAt: Date.now() });
  return schema;
}

function renameError(error: unknown): boolean {
  if (!(error instanceof Error)) return false;
  const message = error.message + (error.cause instanceof Error ? ` ${error.cause.message}` : '');
  return /(?:no such (?:table|column)|has no column named):?\s+(?:\w+\.)?(?:workouts|day_templates|workout_id|day_template_id)\b/i.test(message);
}

async function execute<T>(db: Database, queries: string[], run: (schema: Schema) => Promise<T>): Promise<T> {
  const adaptive = queries.some((query) => workoutSchemaSQL(query, 'legacy') !== query);
  const schema = adaptive ? await schemaFor(db) : 'workouts';
  try { return await run(schema); }
  catch (error) {
    if (!adaptive || !renameError(error)) throw error;
    schemaCache.delete(cacheRoots.get(db) ?? db);
    const fresh = await schemaFor(db, true);
    if (fresh === schema) throw error;
    // A failed statement or D1 atomic batch has committed nothing. Retry that
    // exact unit once; never replay a whole service mutation or a network error.
    return run(fresh);
  }
}

function prepare(db: Database, query: string, values: unknown[] = []): D1PreparedStatement {
  const materialize = (schema: Schema) => db.prepare(workoutSchemaSQL(query, schema)).bind(...values);
  async function first<T = Record<string, unknown>>(column?: string): Promise<T | null> {
    const row = await execute(db, [query], (schema) => materialize(schema).first<Record<string, unknown>>());
    const result = canonicalRow(row);
    if (!result) return null;
    if (column === undefined) return result as T;
    if (!Object.hasOwn(result, column)) throw new Error(`D1_ERROR: column not found: ${column}`);
    return result[column] as T;
  }
  async function raw<T = unknown[]>(options: { columnNames: true }): Promise<[string[], ...T[]]>;
  async function raw<T = unknown[]>(options?: { columnNames?: false }): Promise<T[]>;
  async function raw<T = unknown[]>(options?: { columnNames?: boolean }): Promise<[string[], ...T[]] | T[]> {
    if (options?.columnNames) {
      const [columns, ...rows] = await execute(db, [query], (schema) => materialize(schema).raw<T>({ columnNames: true }));
      return [columns.map(canonicalColumn), ...rows];
    }
    return execute(db, [query], (schema) => materialize(schema).raw<T>());
  }
  // Materialize only at execution. Speculative prepare calls can consume an
  // observer/test facade's single-use interception before its statement runs.
  const statement: D1PreparedStatement = {
    bind: (...bound: unknown[]) => prepare(db, query, bound),
    first,
    raw,
    all: async <T>() => canonicalResult(await execute(db, [query], (schema) => materialize(schema).all<T>())),
    run: async <T>() => canonicalResult(await execute(db, [query], (schema) => materialize(schema).run<T>())),
  };
  statements.set(statement, { query, values, db });
  return statement;
}

async function batch<T>(db: Database, batchStatements: D1PreparedStatement[]): Promise<D1Result<T>[]> {
  const inputs = batchStatements.map((statement) => {
    const input = statements.get(statement);
    if (input && input.db !== db) throw new Error('workout_statement_database_mismatch');
    return input;
  });
  const results = await execute(db, inputs.flatMap((input) => input ? [input.query] : []), (schema) => db.batch<T>(
    batchStatements.map((statement, index) => {
      const input = inputs[index];
      return input ? db.prepare(workoutSchemaSQL(input.query, schema)).bind(...input.values) : statement;
    }),
  ));
  return results.map(canonicalResult);
}

/** Preserve native D1 behavior for unrelated methods. Application schema
 * changes use migration files directly; exec() is deliberately not adapted. */
export function workoutDB(db: D1Database): D1Database {
  const existing = databases.get(db);
  if (existing) return existing;
  const wrapped = new Proxy(db, {
    get(target, property) {
      if (property === 'prepare') return (query: string) => prepare(target, query);
      if (property === 'batch') return <T>(items: D1PreparedStatement[]) => batch<T>(target, items);
      if (property === 'withSession') return (constraint?: D1SessionBookmark | D1SessionConstraint) => {
        const session = target.withSession(constraint);
        return { prepare: (query: string) => prepare(session, query),
          batch: <T>(items: D1PreparedStatement[]) => batch<T>(session, items),
          getBookmark: () => session.getBookmark() } satisfies D1DatabaseSession;
      };
      const value = Reflect.get(target, property, target);
      return typeof value === 'function' ? value.bind(target) : value;
    },
  });
  databases.set(db, wrapped);
  databases.set(wrapped, wrapped);
  return wrapped;
}
