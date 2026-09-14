/** Pure civil-date scheduling rules, shared by REST and MCP. This module has
 * no database or network dependency. CalendarProjection.swift and the shared
 * calendar fixtures define the cross-client parity contract. */
import { WEEKDAYS } from './types';
import type { DayConflict, ExternalActivityRow, ExternalEventRow, SessionRow, Trip, Weekday, WeeklySchedule } from './types';

/**
 * Calendar weekday rule (iOS MUST mirror this byte-for-byte):
 * parse the device-local 'YYYY-MM-DD' string as a proleptic Gregorian date,
 * compute days since the fixed Monday epoch 1970-01-05 using integer day
 * arithmetic (NOT a UTC Date offset, NOT timezone-aware), and index
 * WEEKDAYS = [mon,tue,wed,thu,fri,sat,sun]. 1970-01-05 was a Monday, so
 * ((daysSinceEpoch % 7) + 7) % 7 gives 0=mon ... 6=sun.
 */
function dayNumber(ymd: string): number {
  const parts = ymd.split('-');
  const y = Number(parts[0]);
  const m = Number(parts[1]);
  const d = Number(parts[2]);
  // Days from 1970-01-01 via a pure civil-from-date algorithm (Howard
  // Hinnant's days_from_civil) — no Date object, no UTC, no DST.
  const yy = m <= 2 ? y - 1 : y;
  const era = Math.floor((yy >= 0 ? yy : yy - 399) / 400);
  const yoe = yy - era * 400;
  const doy = Math.floor((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1;
  const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
  return era * 146097 + doe - 719468; // days since 1970-01-01
}

/** 'YYYY-MM-DD' -> weekday key, via the calendar rule above (1970-01-05=Mon). */
export function weekdayOf(ymd: string): Weekday {
  const days = dayNumber(ymd) - 4; // 1970-01-05 (Monday) is day 4
  const idx = ((days % 7) + 7) % 7;
  return WEEKDAYS[idx]!;
}

/** Inclusive day count between two 'YYYY-MM-DD' strings (calendar, not UTC). */
function daySpan(from: string, to: string): number {
  return dayNumber(to) - dayNumber(from);
}

/** Add n days to a 'YYYY-MM-DD' string, returning 'YYYY-MM-DD'. */
export function addDays(ymd: string, n: number): string {
  // Civil-from-days inverse of dayNumber (Hinnant), pure integer math.
  let z = dayNumber(ymd) + n + 719468;
  const era = Math.floor((z >= 0 ? z : z - 146096) / 146097);
  const doe = z - era * 146097;
  const yoe = Math.floor(
    (doe - Math.floor(doe / 1460) + Math.floor(doe / 36524) - Math.floor(doe / 146096)) / 365,
  );
  const y = yoe + era * 400;
  const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
  const mp = Math.floor((5 * doy + 2) / 153);
  const d = doy - Math.floor((153 * mp + 2) / 5) + 1;
  const m = mp < 10 ? mp + 3 : mp - 9;
  const yr = m <= 2 ? y + 1 : y;
  const pad = (x: number, w = 2) => String(x).padStart(w, '0');
  return `${pad(yr, 4)}-${pad(m)}-${pad(d)}`;
}

/**
 * An endurance item on a calendar day (MULTISPORT.md §6.1). These COEXIST
 * with the strength side (`workout_id`) — a brick is a lift + a ride on
 * the same day — so they live in their own array rather than replacing the
 * strength cell. Read-only (endurance executes on the watch); on today+ days
 * these are planned `external_events`, on past days completed
 * `external_activities`. iOS renders them as read-only cards.
 */
export interface EnduranceItem {
  /** external_event / external_activity id (e.g. "intervals:{external_id}"). */
  id: string;
  /** ride | run | swim | other. */
  kind: string;
  title: string | null;
  /** Planned (future) duration; null for completed-actual items. */
  planned_duration_sec: number | null;
  /** TSS-like load (planned or actual). */
  training_load: number | null;
  /** true → a completed actual (past), false → a planned event (today+). */
  completed: boolean;
}

export interface CalendarCell {
  date: string;
  /**
   * The day's coarse status. Strength + endurance + trips collapse into one:
   *   - 'unavailable' — a trip covers the date with can_train_light=false:
   *     no logged strength happened and items is []. A real in_progress/
   *     completed strength session instead keeps its status, but still has
   *     no endurance items. (The trip type remains in `trip_type`.)
   *   - 'light'       — a trip covers the date with can_train_light=true:
   *     training is possible but constrained; items reflect what's planned.
   *   - real session status (planned|in_progress|completed|skipped) — a real
   *     strength sessions row drives it.
   *   - 'projected'   — no real session; the weekly pattern projects a lift.
   *   - 'rest'        — no template that weekday and no items.
   * NOTE: a day with ONLY endurance (no strength) and no trip reports
   * 'projected' (it has planned training) so existing lift-or-not consumers
   * keep working; inspect `items` to distinguish a pure-endurance day.
   */
  status:
    | 'projected'
    | 'rest'
    | 'planned'
    | 'in_progress'
    | 'completed'
    | 'skipped'
    | 'unavailable'
    | 'light';
  /** Set when a template resolves (projected or a real session w/ day). */
  workout_id: string | null;
  /** True iff this cell came from a real sessions row. */
  real: boolean;
  /**
   * Endurance items for the day (bricks / doubles). Empty array when there is
   * no endurance. ADDITIVE — existing single-item strength consumers ignore
   * this and keep reading `status`/`workout_id`/`real` unchanged.
   */
  items: EnduranceItem[];
  /** When status is a trip status ('unavailable'/'light'), the trip.type. */
  trip_type?: string;
  /** True when a hard blackout suppressed both recurring strength and every
   *  endurance event. Real in-progress/completed strength may remain visible,
   *  so consumers cannot infer this solely from `status`. */
  suppresses_schedule_and_endurance?: true;
}

/**
 * A planned endurance event for the projection (future days). Mirror-shape of
 * the relevant ExternalEventRow columns; `date` is the civil YYYY-MM-DD.
 */
export type ProjectionEvent = Pick<
  ExternalEventRow,
  'id' | 'date' | 'kind' | 'title' | 'planned_duration_sec' | 'training_load'
>;

/**
 * A completed endurance actual for the projection (past days). Mirror-shape of
 * the relevant ExternalActivityRow columns.
 */
export type ProjectionActivity = Pick<
  ExternalActivityRow,
  'id' | 'date' | 'kind' | 'name' | 'moving_time_sec' | 'training_load'
>;

/** Index a list by its civil `date` into a Map<date, T[]>. */
function groupByDate<T extends { date: string }>(rows: Iterable<T>): Map<string, T[]> {
  const m = new Map<string, T[]>();
  for (const r of rows) {
    const arr = m.get(r.date);
    if (arr) arr.push(r);
    else m.set(r.date, [r]);
  }
  return m;
}

/**
 * Pure COMPOSITE projection (MULTISPORT.md §6.1). Given the plan, schedule,
 * real sessions, trips, and the endurance feeds (planned events for today+,
 * completed actuals for the past), emit a calendar cell per date. A
 * today-or-future day is a COMPOSITE: a strength side (status/workout_id)
 * PLUS an `items` array of coexisting endurance (bricks/doubles), PLUS a trip
 * status. It stays COMPUTED — no materialized rows.
 *
 * Per civil date:
 *  - date < today (PAST): emit ONLY if there is real history — a real
 *    sessions row (NOT a vanished discarded/planned one) OR a completed
 *    endurance actual. Never fabricate past rest/missed days. items =
 *    completed actuals on the date.
 *  - date >= today (TODAY+):
 *      trip covering date with can_train_light=false:
 *        a real in_progress/completed strength session stays visible with
 *          its own status/template; otherwise status = 'unavailable'.
 *        Either way, items = [] and no schedule/endurance is projected.
 *      else:
 *        strength: a real sessions row wins; else schedule[weekday] template
 *          (cleared if a trip covers the date — a trip blanks the schedule
 *          projection but keeps explicitly-pinned sessions).
 *        endurance: planned external_events on the date COEXIST (items).
 *        status: trip (can_train_light=true) → 'light'; else any strength or
 *          items → its lift/'projected' status; else 'rest'.
 *
 * Weekday is derived from the 'YYYY-MM-DD' string via weekdayOf() (calendar
 * rule, NOT a UTC offset) — iOS must mirror weekdayOf byte-for-byte.
 */
export function projectCalendar(
  plan: { id: string },
  schedule: WeeklySchedule,
  realSessions: SessionRow[],
  fromDate: string,
  toDate: string,
  today: string,
  /** Day-template ids that still exist; a schedule id not here is dangling
   *  and degrades to 'rest'. Pass [] only if you have no plan tree. */
  liveDayIds: Iterable<string> = [],
  /** Availability ranges (meta.trips). A covering trip drives the status. */
  trips: Trip[] = [],
  /** Planned endurance events (future days) — the coexisting brick/double. */
  plannedEvents: ProjectionEvent[] = [],
  /** Completed endurance actuals (past days) — what actually happened. */
  completedActivities: ProjectionActivity[] = [],
): CalendarCell[] {
  void plan;
  const resolvable = new Set(liveDayIds);
  // Clamp the span to 90 days (inclusive endpoint counts as span 0..89).
  let span = daySpan(fromDate, toDate);
  if (span < 0) return [];
  if (span > 89) span = 89;
  const byDate = new Map<string, SessionRow>();
  for (const s of realSessions) {
    // A 'discarded' session is treated as if it never existed: the user
    // explicitly threw it away (its set_logs are soft-deleted by
    // discardSession). Skipping it here makes the date fall through to the
    // schedule projection (past → no cell; today/future → projected/rest)
    // — i.e. it VANISHES rather than showing as a skip. This carve-out is
    // mirrored byte-for-byte in CalendarProjection.swift (`project`): the
    // frozen truth table now reads "a real session WINS *unless* it is
    // 'discarded'". test/calendar.test.ts is the contract.
    if (s.status === 'discarded') continue;
    if (!byDate.has(s.date)) byDate.set(s.date, s);
  }
  const eventsByDate = groupByDate(plannedEvents);
  const actsByDate = groupByDate(completedActivities);

  // Returns the trip covering `date` (first match), or null. A trip range is
  // [start, end] inclusive, compared on the civil YYYY-MM-DD string (the same
  // tz-free rule as weekdayOf/addDays). String compare is valid because the
  // format is zero-padded and sortable.
  const tripFor = (date: string): Trip | null => {
    for (const t of trips) {
      if (date >= t.start && date <= t.end) return t;
    }
    return null;
  };

  const eventItem = (e: ProjectionEvent): EnduranceItem => ({
    id: e.id,
    kind: e.kind,
    title: e.title,
    planned_duration_sec: e.planned_duration_sec,
    training_load: e.training_load,
    completed: false,
  });
  const actItem = (a: ProjectionActivity): EnduranceItem => ({
    id: a.id,
    kind: a.kind,
    title: a.name,
    planned_duration_sec: a.moving_time_sec,
    training_load: a.training_load,
    completed: true,
  });

  const cells: CalendarCell[] = [];
  for (let i = 0; i <= span; i++) {
    const date = addDays(fromDate, i);
    const real = byDate.get(date);
    const isPast = daySpan(today, date) < 0;

    if (isPast) {
      // PAST — show only real history: a real (non-vanished) session and/or
      // completed endurance actuals. A still-'planned' past session never
      // executed (logging flips it to in_progress/completed), so it VANISHES
      // like 'discarded' (#48). Mirrored byte-for-byte in
      // CalendarProjection.swift; calendar.test.ts is the contract.
      const items = (actsByDate.get(date) ?? []).map(actItem);
      if (real && real.status !== 'planned') {
        cells.push({
          date,
          status: real.status as CalendarCell['status'],
          workout_id: real.workout_id,
          real: true,
          items,
        });
      } else if (items.length) {
        // Endurance-only past day: completed actuals with no strength session.
        cells.push({
          date,
          status: 'completed',
          workout_id: null,
          real: false,
          items,
        });
      }
      // else: no real history → no fabricated past cell.
      continue;
    }

    // TODAY or FUTURE.
    const trip = tripFor(date);
    if (trip && trip.can_train_light === false) {
      // BLACKOUT TRUTH TABLE — keep byte-for-byte in backend and iOS:
      //   real in_progress/completed → surface the real session;
      //   real planned/skipped/other, or no real → unavailable.
      // In every case the blackout suppresses schedule and endurance items.
      if (real && (real.status === 'in_progress' || real.status === 'completed')) {
        cells.push({
          date,
          status: real.status,
          workout_id: real.workout_id,
          real: true,
          items: [],
          trip_type: trip.type,
          suppresses_schedule_and_endurance: true,
        });
        continue;
      }
      cells.push({
        date,
        status: 'unavailable',
        workout_id: null,
        real: false,
        items: [],
        trip_type: trip.type,
        suppresses_schedule_and_endurance: true,
      });
      continue;
    }

    // Outside a hard blackout, a real session wins; else the schedule
    // projection, UNLESS a trip covers the date (a trip blanks the recurring
    // pattern — Claude re-plans the week as explicit sessions). An explicitly-
    // pinned real session always survives a light trip.
    let status: CalendarCell['status'];
    let workoutId: string | null;
    let real_ = false;
    if (real) {
      status = real.status as CalendarCell['status'];
      workoutId = real.workout_id;
      real_ = true;
    } else {
      const tid = trip ? null : schedule.week[weekdayOf(date)];
      if (tid && resolvable.has(tid)) {
        status = 'projected';
        workoutId = tid;
      } else {
        status = 'rest';
        workoutId = null;
      }
    }

    // Endurance side coexists (brick / double).
    const items = (eventsByDate.get(date) ?? []).map(eventItem);

    // Resolve the composite status.
    let finalStatus = status;
    if (trip) {
      // can_train_light=true → constrained but possible. A pinned real
      // session keeps its own status; otherwise the day is 'light'.
      finalStatus = real_ ? status : 'light';
    } else if (status === 'rest' && items.length) {
      // Pure-endurance day (no strength) → report 'projected' so existing
      // lift-or-not consumers see planned training; items disambiguate.
      finalStatus = 'projected';
    }

    const cell: CalendarCell = {
      date,
      status: finalStatus,
      workout_id: workoutId,
      real: real_,
      items,
    };
    if (trip) cell.trip_type = trip.type;
    cells.push(cell);
  }
  return cells;
}

/** Everything `projectCalendar` needs that lives in D1. Read once over the
 *  widest window a caller needs; `projectCalendarWindow` then narrows the
 *  windowed collections per projection, so each projection sees exactly the
 *  rows its own window query would have returned. */
export interface CalendarInputs {
  plan: { id: string };
  schedule: WeeklySchedule;
  trips: Trip[];
  liveDayIds: string[];
  /** All three below cover the read window, not necessarily the projected one. */
  plannedEvents: ProjectionEvent[];
  completedActivities: ProjectionActivity[];
  sessions: SessionRow[];
}

/** Project one window out of already-read rows. The algorithm itself stays in
 *  `projectCalendar` — mirrored byte-for-byte in CalendarProjection.swift. */
export function projectCalendarWindow(
  inputs: CalendarInputs,
  fromDate: string,
  toDate: string,
  today: string,
): CalendarCell[] {
  // `date` is a civil YYYY-MM-DD string, so this is the same lexicographic
  // comparison the `date >= ?2 AND date <= ?3` predicates perform.
  const inWindow = (row: { date: string }) => row.date >= fromDate && row.date <= toDate;
  return projectCalendar(
    inputs.plan,
    inputs.schedule,
    inputs.sessions.filter(inWindow),
    fromDate,
    toDate,
    today,
    inputs.liveDayIds,
    inputs.trips,
    inputs.plannedEvents.filter(inWindow),
    inputs.completedActivities.filter(inWindow),
  );
}

/** Scheduling heuristic, mirrored by Swift. These fixed thresholds use only
 * planned endurance load/duration and lift dates; they cannot establish
 * individualized interference or safety. One missing measure leaves context
 * incomplete even when the other is known. Same-day takes priority. */
export function detectConflicts(
  liftDates: Iterable<string>,
  events: Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>[],
): DayConflict[] {
  const byDate = new Map<string, typeof events>();
  for (const e of events) {
    const arr = byDate.get(e.date);
    if (arr) arr.push(e);
    else byDate.set(e.date, [e]);
  }
  const isHard = (e: { training_load: number | null; planned_duration_sec: number | null }) =>
    (e.training_load ?? 0) >= 150 || (e.planned_duration_sec ?? 0) >= 9000;

  const out: DayConflict[] = [];
  // Dedupe + stable order: iterate sorted unique lift dates.
  const dates = [...new Set(liftDates)].sort();
  for (const d of dates) {
    const sameDay = byDate.get(d);
    if (sameDay && sameDay.length) {
      // Known threshold evidence wins; missing inputs never mean easy work.
      const severity: DayConflict['severity'] = sameDay.some(isHard) ? 'clash'
        : sameDay.some(e => e.training_load == null || e.planned_duration_sec == null) ? 'unknown' : 'brick';
      out.push({ date: d, conflicts: sameDay.map((e) => e.id), severity });
      continue;
    }
    const next = byDate.get(addDays(d, 1));
    if (next) {
      const hard = next.filter(isHard);
      if (hard.length) {
        out.push({ date: d, conflicts: hard.map((e) => e.id), severity: 'heavy-next-day' });
      } else {
        const incomplete = next.filter(e => e.training_load == null || e.planned_duration_sec == null);
        if (incomplete.length) out.push({ date: d, conflicts: incomplete.map(e => e.id), severity: 'unknown' });
      }
    }
  }
  return out;
}

export type StrengthCalendarInputs = Omit<CalendarInputs, 'plannedEvents' | 'completedActivities'>;

/** Conflict detection needs only the strength side of the calendar. Endurance
 * items can change a cell's display status, but cannot create a lift or change
 * blackout suppression. Reuse the same projection with empty endurance feeds;
 * the caller supplies the live planned-event window separately, including the
 * next-day boundary. No completed-activity read is needed. */
export function projectRideConflicts(
  strength: StrengthCalendarInputs,
  events: Pick<ExternalEventRow, 'id' | 'date' | 'training_load' | 'planned_duration_sec'>[],
  fromDate: string,
  toDate: string,
  today: string,
): DayConflict[] {
  // Conflict detection reads one day beyond the visible range for its
  // next-day warning, so projection/suppression must cover that same day.
  const inputs: CalendarInputs = {
    ...strength,
    plannedEvents: [],
    completedActivities: [],
  };
  const cal = projectCalendarWindow(inputs, fromDate, toDate, today);
  // `projectCalendar` intentionally caps one call at 90 cells. Probe the
  // visible boundary separately so a max-range request still learns that the
  // day after its final projected lift is a hard blackout. Without this small
  // window, a hard ride suppressed on that blackout could leak back as a
  // false heavy-next-day conflict.
  const boundaryCal = projectCalendarWindow(inputs, toDate, addDays(toDate, 1), today);
  const suppressedDates = new Set(
    [...cal, ...boundaryCal]
      .filter((c) => c.suppresses_schedule_and_endurance === true)
      .map((c) => c.date),
  );
  // A LIFT date carries actual STRENGTH (the conflict subject) — NOT a pure
  // endurance day. The composite projection now also reports 'projected'/
  // 'completed' for endurance-only days, distinguishable by the absence of a
  // strength template/session: a real strength session (planned|in_progress|
  // completed) OR a projected strength template (workout_id != null).
  // 'skipped' lifts and pure-endurance cells (workout_id == null and
  // !real) are excluded, keeping the prior contract intact.
  const liftDates = cal
    .filter(
      (c) =>
        c.date <= toDate &&
        !c.suppresses_schedule_and_endurance &&
        ((c.real && (c.status === 'planned' || c.status === 'in_progress' || c.status === 'completed')) ||
          (c.status === 'projected' && c.workout_id != null)),
    )
    .map((c) => c.date);
  return detectConflicts(liftDates, events.filter((event) => !suppressedDates.has(event.date)));
}
