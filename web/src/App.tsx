import { useEffect, useMemo, useState } from 'react';
import { fetchMe, fetchState, signOut, SignedOutError, type Me, type StateResponse } from './api';
import {
  activityLoads,
  calendarInputs,
  describeRunSteps,
  describeSlot,
  ENDURANCE_LABELS,
  formatClock,
  formatLongDate,
  formatMonth,
  itemLoad,
  LOAD_METHOD_LABELS,
  localToday,
  monthOf,
  monthWeeks,
  orderedSlots,
  prefersMiles,
  projectRange,
  shiftMonth,
  STATUS_LABELS,
  tripOn,
  WEEKDAY_LABELS,
  type CalendarCell,
  type ShownLoad,
  type Workout,
} from './model';
import { WEEKDAYS, type WeeklySchedule } from '../../src/types';

type Load =
  | { kind: 'loading' }
  | { kind: 'signed_out' }
  | { kind: 'error'; message: string }
  | { kind: 'ready'; me: Me; state: StateResponse };

const SIGNIN_PROBLEMS: Record<string, string> = {
  cancelled: 'Sign in was cancelled.',
  failed: 'Sign in didn’t work. Please try again.',
  unavailable: 'This account can’t be used right now.',
};

export function App() {
  const [load, setLoad] = useState<Load>({ kind: 'loading' });

  useEffect(() => {
    let live = true;
    Promise.all([fetchMe(), fetchState()])
      .then(([me, state]) => live && setLoad({ kind: 'ready', me, state }))
      .catch((error: unknown) => {
        if (!live) return;
        if (error instanceof SignedOutError) setLoad({ kind: 'signed_out' });
        else setLoad({ kind: 'error', message: 'Your plan couldn’t be loaded. Refresh to try again.' });
      });
    return () => { live = false; };
  }, []);

  if (load.kind === 'loading') return <main className="centered" aria-busy="true"><p className="muted">Loading your plan…</p></main>;
  if (load.kind === 'signed_out') return <SignIn />;
  if (load.kind === 'error') return <main className="centered"><p role="alert">{load.message}</p></main>;
  return <Planner me={load.me} state={load.state} onSignedOut={() => setLoad({ kind: 'signed_out' })} />;
}

function SignIn() {
  const problem = new URLSearchParams(window.location.search).get('signin');
  return (
    <main className="signin">
      <div className="signin-card">
        <img src="/assets/app-icon.png" alt="" width={72} height={72} />
        <h1 className="wordmark">Très Fort</h1>
        <p className="lede">Everything you train. One plan.</p>
        <p className="muted">Plan your week and review your training on a bigger screen. Sign in with the same Apple account you use in the iPhone app.</p>
        {problem && SIGNIN_PROBLEMS[problem] && <p role="alert" className="problem">{SIGNIN_PROBLEMS[problem]}</p>}
        <a className="apple-button" href="/auth/apple/start">
          <AppleLogo /> Sign in with Apple
        </a>
        <p className="fine">Training happens in the iPhone app. New here? Signing in creates your account.</p>
      </div>
    </main>
  );
}

function AppleLogo() {
  return (
    <svg aria-hidden="true" viewBox="0 0 24 24" width="18" height="18" focusable="false">
      <path fill="currentColor" d="M16.365 1.43c0 1.14-.493 2.27-1.177 3.08-.744.9-1.99 1.57-2.987 1.57-.12 0-.23-.02-.3-.03-.01-.06-.04-.22-.04-.39 0-1.15.572-2.27 1.206-2.98.804-.94 2.142-1.64 3.248-1.68.03.13.05.28.05.43zm4.565 15.71c-.03.07-.463 1.58-1.518 3.12-.945 1.34-1.94 2.71-3.43 2.71-1.517 0-1.9-.88-3.63-.88-1.698 0-2.302.91-3.67.91-1.377 0-2.332-1.26-3.428-2.8-1.287-1.82-2.323-4.63-2.323-7.28 0-4.28 2.797-6.55 5.552-6.55 1.448 0 2.675.95 3.6.95.865 0 2.222-1.01 3.902-1.01.613 0 2.886.06 4.374 2.19-.13.09-2.383 1.37-2.383 4.19 0 3.26 2.854 4.42 2.955 4.45z" />
    </svg>
  );
}

function Planner({ me, state, onSignedOut }: { me: Me; state: StateResponse; onSignedOut: () => void }) {
  const today = useMemo(() => localToday(), []);
  const [month, setMonth] = useState(monthOf(today));
  const [selected, setSelected] = useState(today);
  const miles = useMemo(() => prefersMiles(), []);
  const plan = state.plan;
  const inputs = useMemo(() => calendarInputs(state), [state]);
  const weeks = useMemo(() => monthWeeks(month), [month]);
  const cells = useMemo(() => {
    if (!inputs) return new Map<string, CalendarCell>();
    return projectRange(inputs, weeks[0]![0]!, weeks[weeks.length - 1]![6]!, today);
  }, [inputs, weeks, today]);
  const selectedCell = useMemo(
    () => cells.get(selected) ?? (inputs ? projectRange(inputs, selected, selected, today).get(selected) : undefined),
    [cells, inputs, selected, today],
  );
  const workouts = useMemo(() => new Map((plan?.workouts ?? []).map((w) => [w.id, w])), [plan]);
  const loads = useMemo(() => activityLoads(state), [state]);

  async function handleSignOut() {
    await signOut();
    onSignedOut();
  }

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand"><img src="/assets/app-icon.png" alt="" width={32} height={32} /><span className="wordmark">Très Fort</span></div>
        <div className="account">
          <span className="muted">{me.display_name ?? me.email ?? 'Signed in'}</span>
          <button type="button" className="ghost" onClick={handleSignOut}>Sign out</button>
        </div>
      </header>

      {!plan ? (
        <main className="centered">
          <h1>No plan yet</h1>
          <p className="muted">Open the iPhone app to pick a starter workout. Planning on the web is coming next.</p>
        </main>
      ) : (
        <main className="planner">
          <section className="calendar" aria-labelledby="month-title">
            <div className="calendar-head">
              <h1 id="month-title">{formatMonth(month)}</h1>
              <div className="month-nav">
                <button type="button" onClick={() => setMonth(shiftMonth(month, -1))} aria-label="Previous month">‹</button>
                <button type="button" onClick={() => { setMonth(monthOf(today)); setSelected(today); }}>Today</button>
                <button type="button" onClick={() => setMonth(shiftMonth(month, 1))} aria-label="Next month">›</button>
              </div>
            </div>
            <div className="grid" role="grid" aria-labelledby="month-title">
              <div className="grid-row weekdays" role="row">
                {WEEKDAYS.map((day) => <div key={day} role="columnheader">{WEEKDAY_LABELS[day].slice(0, 3)}</div>)}
              </div>
              {weeks.map((week) => (
                <div className="grid-row" role="row" key={week[0]}>
                  {week.map((date) => (
                    <DayCell
                      key={date}
                      date={date}
                      cell={cells.get(date)}
                      workout={workoutFor(cells.get(date), workouts)}
                      inMonth={monthOf(date) === month}
                      isToday={date === today}
                      isSelected={date === selected}
                      onSelect={() => setSelected(date)}
                    />
                  ))}
                </div>
              ))}
            </div>
            <WeeklyRoutine schedule={plan.schedule} workouts={workouts} />
          </section>

          <DayDetail
            date={selected}
            cell={selectedCell}
            workout={workoutFor(selectedCell, workouts)}
            trip={tripOn(selected, plan.trips ?? [])}
            miles={miles}
            loads={loads}
          />
        </main>
      )}
    </div>
  );
}

function workoutFor(cell: CalendarCell | undefined, workouts: Map<string, Workout>): Workout | undefined {
  return cell?.workout_id ? workouts.get(cell.workout_id) : undefined;
}

function DayCell(props: {
  date: string;
  cell: CalendarCell | undefined;
  workout: Workout | undefined;
  inMonth: boolean;
  isToday: boolean;
  isSelected: boolean;
  onSelect: () => void;
}) {
  const { date, cell, workout, inMonth, isToday, isSelected, onSelect } = props;
  const status = cell?.status;
  const classes = ['day', inMonth ? '' : 'outside', isToday ? 'today' : '', isSelected ? 'selected' : '', status ? `status-${status}` : '']
    .filter(Boolean).join(' ');
  const label = `${formatLongDate(date)}${status ? `, ${STATUS_LABELS[status]}` : ''}${workout ? `, ${workout.name}` : ''}`;
  return (
    <button type="button" role="gridcell" className={classes} onClick={onSelect} aria-label={label} aria-pressed={isSelected}>
      <span className="day-number">{Number(date.slice(8))}</span>
      {status === 'unavailable' || status === 'light' ? <span className="chip away">Away</span> : null}
      {workout && status !== 'rest' ? <span className={`chip lift ${status ?? ''}`}>{workout.name}</span> : null}
      {cell?.items.map((item) => (
        <span key={item.id} className={`chip endurance ${item.completed ? 'completed' : ''}`}>
          {item.title ?? ENDURANCE_LABELS[item.kind] ?? 'Activity'}
        </span>
      ))}
    </button>
  );
}

function WeeklyRoutine({ schedule, workouts }: { schedule: WeeklySchedule; workouts: Map<string, Workout> }) {
  return (
    <section className="routine" aria-labelledby="routine-title">
      <h2 id="routine-title">Weekly routine</h2>
      <ol>
        {WEEKDAYS.map((day) => {
          const workoutId = schedule.week[day];
          const workout = workoutId ? workouts.get(workoutId) : undefined;
          return (
            <li key={day}>
              <span className="muted">{WEEKDAY_LABELS[day]}</span>
              <span>{workout ? workout.name : 'Rest'}</span>
            </li>
          );
        })}
      </ol>
    </section>
  );
}

function DayDetail(props: {
  date: string;
  cell: CalendarCell | undefined;
  workout: Workout | undefined;
  trip: ReturnType<typeof tripOn>;
  miles: boolean;
  loads: Map<string, ShownLoad | null>;
}) {
  const { date, cell, workout, trip, miles, loads } = props;
  return (
    <aside className="detail" aria-labelledby="detail-title">
      <h2 id="detail-title">{formatLongDate(date)}</h2>
      <p className="status-line">{cell ? STATUS_LABELS[cell.status] : 'Nothing recorded'}</p>
      {trip && (
        <div className="note">
          <strong>Away</strong> {trip.start} to {trip.end}
          {trip.can_train_light ? ', light training possible' : ''}
          {trip.note ? <p className="muted">{trip.note}</p> : null}
        </div>
      )}
      {workout && cell?.status !== 'rest' && cell?.status !== 'unavailable' && (
        <section>
          <h3>{workout.name}</h3>
          {workout.notes ? <p className="muted">{workout.notes}</p> : null}
          <ol className="slots">
            {orderedSlots(workout).map((slot) => {
              const steps = describeRunSteps(slot.run_steps, miles);
              return (
                <li key={slot.id} className={slot.is_warmup ? 'warmup' : ''}>
                  <div className="slot-name">
                    {slot.group_label ? <span className="group">{slot.group_label}</span> : null}
                    {slot.exercise_name}
                    {slot.is_warmup ? <span className="tag">Warm-up</span> : null}
                  </div>
                  {steps.length ? (
                    <ul className="steps">{steps.map((line, i) => <li key={i}>{line}</li>)}</ul>
                  ) : (
                    <div className="muted">{describeSlot(slot)}</div>
                  )}
                </li>
              );
            })}
          </ol>
        </section>
      )}
      {cell?.items.length ? (
        <section>
          <h3>Endurance</h3>
          <ul className="slots">
            {cell.items.map((item) => {
              const load = itemLoad(item, loads);
              const method = load?.method ? LOAD_METHOD_LABELS[load.method] : undefined;
              return (
                <li key={item.id}>
                  <div className="slot-name">{item.title ?? ENDURANCE_LABELS[item.kind] ?? 'Activity'}</div>
                  <div className="muted">
                    {ENDURANCE_LABELS[item.kind] ?? 'Activity'} · {item.completed ? 'Done' : 'Planned'}
                    {item.planned_duration_sec ? ` · ${formatClock(item.planned_duration_sec)}` : ''}
                    {load ? ` · load ${Math.round(load.load)}${method ? ` (${method})` : ''}` : ''}
                  </div>
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}
      {!workout && !cell?.items.length && !trip ? <p className="muted">A rest day.</p> : null}
      <p className="fine">Editing on the web is coming next. For now, change your plan in the iPhone app.</p>
    </aside>
  );
}
