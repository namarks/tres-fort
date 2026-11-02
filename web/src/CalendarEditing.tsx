import { useEffect, useId, useRef, useState, type DragEvent, type FormEvent, type ReactNode } from 'react';
import { WEEKDAYS, type Trip, type Weekday, type WeeklySchedule } from '../../src/types';
import { dateWrites, planWrites, type StateResponse } from './api';
import { formatLongDate, WEEKDAY_LABELS, type CalendarCell, type Workout } from './model';
import {
  AWAY_KINDS,
  NOTE_LIMIT,
  attemptOn,
  awayDraft,
  awayFields,
  awayKindLabel,
  choosableWorkouts,
  dateChangeBlocked,
  hasWorkout,
  moveBlocked,
  splitTrips,
  weekWith,
  type AwayDraft,
} from './scheduling';
import type { Write } from './WorkoutEditor';

const DRAG_TYPE = 'application/x-tresfort-workout';

/**
 * The weekly routine: a workout or rest for each weekday. Pick one from a
 * day's list, or drag a workout onto a day.
 */
export function RoutineEditor(props: { schedule: WeeklySchedule; workouts: Workout[]; write: Write; busy: boolean }) {
  const { schedule, workouts, write, busy } = props;
  const choosable = choosableWorkouts(workouts);
  const [over, setOver] = useState<Weekday | null>(null);
  const ids = useId();

  const save = (day: Weekday, workoutId: string | null) => {
    if ((schedule.week[day] ?? null) === workoutId) return;
    void write((at) => planWrites.setRoutine(weekWith(schedule.week, day, workoutId), at));
  };
  const drop = (day: Weekday) => (event: DragEvent) => {
    event.preventDefault();
    setOver(null);
    const workoutId = event.dataTransfer.getData(DRAG_TYPE);
    if (workoutId === 'rest') save(day, null);
    else if (choosable.some((workout) => workout.id === workoutId)) save(day, workoutId);
  };
  const dragOver = (day: Weekday) => (event: DragEvent) => {
    if (busy || !event.dataTransfer.types.includes(DRAG_TYPE)) return;
    event.preventDefault();
    event.dataTransfer.dropEffect = 'copy';
    setOver(day);
  };

  return (
    <section className="routine" aria-labelledby="routine-title">
      <h2 id="routine-title">Weekly routine</h2>
      <p className="muted hint">Choose a workout or rest for each weekday, or drag a workout onto a day. Single dates on the calendar can still differ.</p>
      {choosable.length > 0 && (
        <ul className="palette" aria-label="Workouts you can drag onto a weekday">
          {[...choosable.map((workout) => ({ id: workout.id, name: workout.name })), { id: 'rest', name: 'Rest' }].map((entry) => (
            <li key={entry.id} draggable={!busy} className={entry.id === 'rest' ? 'rest' : ''}
              onDragStart={(event) => {
                event.dataTransfer.setData(DRAG_TYPE, entry.id);
                event.dataTransfer.effectAllowed = 'copy';
              }}>
              {entry.name}
            </li>
          ))}
        </ul>
      )}
      <ol>
        {WEEKDAYS.map((day) => {
          const current = schedule.week[day] ?? null;
          const known = current === null || choosable.some((workout) => workout.id === current);
          return (
            <li key={day} className={over === day ? 'drop' : ''} onDragOver={dragOver(day)}
              onDragLeave={() => setOver((value) => (value === day ? null : value))} onDrop={drop(day)}>
              <label htmlFor={`${ids}-${day}`} className="muted">{WEEKDAY_LABELS[day]}</label>
              <select id={`${ids}-${day}`} value={current ?? ''} disabled={busy}
                onChange={(event) => save(day, event.target.value || null)}>
                <option value="">Rest</option>
                {!known && <option value={current!}>A removed workout</option>}
                {choosable.map((workout) => <option key={workout.id} value={workout.id}>{workout.name}</option>)}
              </select>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

type DatePanel = 'change' | 'move' | 'remove' | null;

/**
 * This date only: choose or change its workout, move it to another date, or
 * make it rest. The weekly routine and the saved workout stay as they are.
 */
export function DateActions(props: {
  date: string;
  today: string;
  cell: CalendarCell | undefined;
  workout: Workout | undefined;
  state: StateResponse;
  cellFor: (date: string) => CalendarCell | undefined;
  write: Write;
  busy: boolean;
}) {
  const { date, today, cell, workout, state, cellFor, write, busy } = props;
  const [panel, setPanel] = useState<DatePanel>(null);
  const sessions = state.sessions;
  const workouts = choosableWorkouts(state.plan?.workouts ?? []);
  const showsWorkout = hasWorkout(cell) && !!workout;
  // Another date, or a newer plan, closes any open form.
  useEffect(() => setPanel(null), [date, state]);
  if (date < today || !state.plan) return null;
  const blocked = dateChangeBlocked(date, today, cell, sessions);
  if (blocked) return <p className="fine">{blocked}</p>;
  const plannedRow = sessions.some((session) => session.date === date && session.status === 'planned');
  const close = () => setPanel(null);
  const done = async (saved: Promise<boolean>) => { if (await saved) close(); };

  return (
    <section className="date-actions" aria-label="This date only">
      {panel === null && (
        <div className="head-actions">
          <button type="button" className="ghost small" disabled={busy} onClick={() => setPanel('change')}>
            {showsWorkout ? 'Change workout' : 'Choose a workout'}
          </button>
          {showsWorkout && <button type="button" className="ghost small" disabled={busy} onClick={() => setPanel('move')}>Move to another date</button>}
          {(showsWorkout || plannedRow) && cell?.status !== 'rest' && (
            <button type="button" className="ghost small danger" disabled={busy} onClick={() => setPanel('remove')}>Make it a rest day</button>
          )}
        </div>
      )}
      {panel === 'change' && (
        <ChooseWorkout
          workouts={workouts}
          current={showsWorkout ? workout!.id : null}
          busy={busy}
          onCancel={close}
          onChoose={(workoutId) => done(write(() => dateWrites.setDate(date, workoutId, attemptOn(sessions, date))))}
        />
      )}
      {panel === 'move' && workout && (
        <MoveWorkout
          from={date}
          today={today}
          workout={workout}
          busy={busy}
          problem={(to) => moveBlocked({ from: date, to, today, fromCell: cell, toCell: cellFor(to), sessions })}
          onCancel={close}
          onMove={(to) => done(write((at) => dateWrites.moveDate({
            from: date, to, today, workoutId: workout.id,
            fromAttempt: attemptOn(sessions, date), toAttempt: attemptOn(sessions, to),
          }, at)))}
        />
      )}
      {panel === 'remove' && (
        <ConfirmPanel action="Make it a rest day" busy={busy} onCancel={close}
          onConfirm={() => done(write(() => dateWrites.setDate(date, null, attemptOn(sessions, date))))}>
          {formatLongDate(date)} becomes a rest day. The saved workout and your weekly routine stay as they are.
        </ConfirmPanel>
      )}
    </section>
  );
}

function ChooseWorkout(props: {
  workouts: Workout[];
  current: string | null;
  busy: boolean;
  onChoose: (workoutId: string) => void;
  onCancel: () => void;
}) {
  const { workouts, current, busy, onChoose, onCancel } = props;
  const [choice, setChoice] = useState(workouts.find((workout) => workout.id !== current)?.id ?? '');
  const id = useId();
  if (workouts.length === 0) {
    return (
      <div className="panel">
        <p className="muted">There are no workouts to choose. Build one in Workouts first.</p>
        <div className="form-actions"><button type="button" className="ghost" onClick={onCancel}>Cancel</button></div>
      </div>
    );
  }
  return (
    <form className="panel" onSubmit={(event) => { event.preventDefault(); if (choice) onChoose(choice); }}>
      <label htmlFor={id}>Workout for this date only</label>
      <select id={id} value={choice} onChange={(event) => setChoice(event.target.value)} autoFocus>
        {workouts.map((workout) => (
          <option key={workout.id} value={workout.id}>{workout.name}{workout.id === current ? ' (now)' : ''}</option>
        ))}
      </select>
      <div className="form-actions">
        <button type="submit" disabled={busy || !choice || choice === current}>Save</button>
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}

function MoveWorkout(props: {
  from: string;
  today: string;
  workout: Workout;
  busy: boolean;
  problem: (to: string) => string | null;
  onMove: (to: string) => void;
  onCancel: () => void;
}) {
  const { from, today, workout, busy, problem, onMove, onCancel } = props;
  const [to, setTo] = useState('');
  const id = useId();
  const reason = to ? problem(to) : null;
  return (
    <form className="panel" onSubmit={(event) => { event.preventDefault(); if (to && !reason) onMove(to); }}>
      <label htmlFor={id}>Move {workout.name} to</label>
      <input id={id} type="date" min={today} value={to} onChange={(event) => setTo(event.target.value)}
        aria-describedby={`${id}-hint`} autoFocus />
      <small id={`${id}-hint`} className="muted">{formatLongDate(from)} becomes a rest day. Your saved workout and weekly routine stay the same.</small>
      {reason && <p role="alert" className="problem">{reason}</p>}
      <div className="form-actions">
        <button type="submit" disabled={busy || !to || !!reason}>Move workout</button>
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}

function ConfirmPanel(props: { children: ReactNode; action: string; busy: boolean; onConfirm: () => void; onCancel: () => void }) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => cancelRef.current?.focus(), []);
  return (
    <div className="panel confirm" role="group" aria-label={props.action}>
      <p>{props.children}</p>
      <div className="form-actions">
        <button type="button" className="danger-fill" disabled={props.busy} onClick={props.onConfirm}>{props.action}</button>
        <button ref={cancelRef} type="button" className="ghost" onClick={props.onCancel}>Cancel</button>
      </div>
    </div>
  );
}

/** Trips, planned rest and injuries that pause the weekly routine. */
export function AwayDates(props: { trips: Trip[]; today: string; version: number; write: Write; busy: boolean }) {
  const { trips, today, version, write, busy } = props;
  const [editing, setEditing] = useState<{ trip: Trip | null } | null>(null);
  const [removing, setRemoving] = useState<Trip | null>(null);
  const [showPast, setShowPast] = useState(false);
  // A newer plan closes any open form, so a stale one can't overwrite it.
  useEffect(() => { setEditing(null); setRemoving(null); }, [version]);
  const { upcoming, past } = splitTrips(trips, today);

  const row = (trip: Trip) => (
    <li key={trip.id}>
      <div className="away-row">
        <div>
          <div>{tripRange(trip)}</div>
          <div className="muted">{awayKindLabel(trip)}</div>
          {trip.note ? <div className="muted">{trip.note}</div> : null}
        </div>
        <div className="row-actions">
          <button type="button" className="ghost small" disabled={busy} onClick={() => setEditing({ trip })}
            aria-label={`Edit away dates ${tripRange(trip)}`}>Edit</button>
          <button type="button" className="ghost small danger" disabled={busy} onClick={() => setRemoving(trip)}
            aria-label={`Remove away dates ${tripRange(trip)}`}>Remove</button>
        </div>
      </div>
      {editing?.trip?.id === trip.id && (
        <AwayForm trip={trip} today={today} busy={busy} onCancel={() => setEditing(null)}
          onSave={(fields) => write((at) => planWrites.updateAwayDates(trip.id, fields, at)).then((saved) => { if (saved) setEditing(null); })} />
      )}
      {removing?.id === trip.id && (
        <ConfirmPanel action="Remove away dates" busy={busy} onCancel={() => setRemoving(null)}
          onConfirm={() => write((at) => planWrites.removeAwayDates(trip.id, at)).then((saved) => { if (saved) setRemoving(null); })}>
          Remove {tripRange(trip)}? Your weekly routine applies to these days again.
        </ConfirmPanel>
      )}
    </li>
  );

  return (
    <section className="away" aria-labelledby="away-title">
      <div className="section-head">
        <h2 id="away-title">Away dates</h2>
        {!editing && <button type="button" className="ghost small" disabled={busy} onClick={() => setEditing({ trip: null })}>Add away dates</button>}
      </div>
      <p className="muted hint">Your weekly routine pauses on these days.</p>
      {editing && editing.trip === null && (
        <AwayForm trip={null} today={today} busy={busy} onCancel={() => setEditing(null)}
          onSave={(fields) => write((at) => planWrites.addAwayDates(fields, at)).then((saved) => { if (saved) setEditing(null); })} />
      )}
      {upcoming.length ? <ul className="away-list">{upcoming.map(row)}</ul> : <p className="muted">Nothing coming up.</p>}
      {past.length > 0 && (
        <>
          <button type="button" className="ghost small" onClick={() => setShowPast(!showPast)} aria-expanded={showPast}>
            {showPast ? 'Hide past away dates' : `Show past away dates (${past.length})`}
          </button>
          {showPast && <ul className="away-list">{past.map(row)}</ul>}
        </>
      )}
    </section>
  );
}

function tripRange(trip: Trip): string {
  const short = (date: string) => new Date(`${date}T12:00:00`).toLocaleDateString(undefined, { weekday: 'short', day: 'numeric', month: 'short' });
  return trip.start === trip.end ? short(trip.start) : `${short(trip.start)} – ${short(trip.end)}`;
}

function AwayForm(props: {
  trip: Trip | null;
  today: string;
  busy: boolean;
  onSave: (fields: Record<string, unknown>) => void;
  onCancel: () => void;
}) {
  const { trip, today, busy, onSave, onCancel } = props;
  const [draft, setDraft] = useState<AwayDraft>(() => awayDraft(trip, today));
  const [error, setError] = useState<string | null>(null);
  const id = useId();
  const set = (patch: Partial<AwayDraft>) => setDraft((current) => {
    const next = { ...current, ...patch };
    // Moving the first day past the last day moves the last day with it.
    if (patch.start && next.end < next.start) next.end = next.start;
    return next;
  });

  function submit(event: FormEvent) {
    event.preventDefault();
    const result = awayFields(draft, trip);
    if (!result.ok) return setError(result.error);
    setError(null);
    if (Object.keys(result.fields).length === 0) return onCancel();
    onSave(result.fields);
  }

  return (
    <form className="panel away-form" onSubmit={submit} noValidate aria-label={trip ? 'Edit away dates' : 'Add away dates'}>
      <div className="field-row">
        <div className="field">
          <label htmlFor={`${id}-start`}>First day</label>
          <input id={`${id}-start`} type="date" value={draft.start} onChange={(e) => set({ start: e.target.value })} autoFocus />
        </div>
        <div className="field">
          <label htmlFor={`${id}-end`}>Last day</label>
          <input id={`${id}-end`} type="date" min={draft.start} value={draft.end} onChange={(e) => set({ end: e.target.value })} />
        </div>
        <div className="field">
          <label htmlFor={`${id}-type`}>Reason</label>
          <select id={`${id}-type`} value={draft.type} onChange={(e) => set({ type: e.target.value as AwayDraft['type'] })}>
            {AWAY_KINDS.map((kind) => <option key={kind.type} value={kind.type}>{kind.label}</option>)}
          </select>
        </div>
      </div>
      <label className="check">
        <input type="checkbox" checked={draft.canTrain} onChange={(e) => set({ canTrain: e.target.checked })} aria-describedby={`${id}-train`} />
        I can still train
      </label>
      <small id={`${id}-train`} className="muted">
        {draft.canTrain
          ? 'Your weekly routine pauses on these days. You can still put a workout on one of them.'
          : 'These days are blocked: your weekly routine pauses and no workout can go on them.'}
      </small>
      <div className="field">
        <label htmlFor={`${id}-note`}>Note</label>
        <input id={`${id}-note`} value={draft.note} maxLength={NOTE_LIMIT} placeholder="Optional, such as hotel gym only"
          onChange={(e) => set({ note: e.target.value })} />
      </div>
      {error && <p role="alert" className="problem">{error}</p>}
      <div className="form-actions">
        <button type="submit" disabled={busy}>{busy ? 'Saving…' : trip ? 'Save' : 'Add away dates'}</button>
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}
