import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react';
import {
  fetchExercises,
  fetchMe,
  fetchState,
  isVersionConflict,
  ApiError,
  planWrites,
  signOut,
  SignedOutError,
  type Me,
  type Reviewed,
  type StateResponse,
} from './api';
import { describeWriteError } from './editing';
import { WorkoutsPage, type Catalog, type Write } from './WorkoutEditor';
import { AwayDates, DateActions, RoutineEditor } from './CalendarEditing';
import { RouteMap } from './RouteMapView';
import { routableActivityIds } from './routeMap';
import {
  activityLoads,
  activitySports,
  itemTitle,
  itemType,
  calendarInputs,
  describeGroup,
  describeRunSteps,
  describeSlot,
  formatClock,
  formatLongDate,
  formatMonth,
  itemLoad,
  LOAD_METHOD_LABELS,
  localToday,
  monthOf,
  monthWeeks,
  prefersMiles,
  projectRange,
  shiftMonth,
  slotBlocks,
  STATUS_LABELS,
  tripOn,
  WEEKDAY_LABELS,
  type CalendarCell,
  type ShownLoad,
  type Slot,
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

  // After a write, the page shows the plan as the API now has it.
  const reload = useCallback(async () => {
    const state = await fetchState();
    setLoad((current) => current.kind === 'ready' ? { ...current, state } : current);
  }, []);

  if (load.kind === 'loading') return <main className="centered" aria-busy="true"><p className="muted">Loading your plan…</p></main>;
  if (load.kind === 'signed_out') return <SignIn />;
  if (load.kind === 'error') return <main className="centered"><p role="alert">{load.message}</p></main>;
  return <Planner me={load.me} state={load.state} reload={reload} onSignedOut={() => setLoad({ kind: 'signed_out' })} />;
}

type View = { kind: 'calendar' } | { kind: 'workouts'; workoutId: string | null };

/** `#workouts` and `#workouts/<id>` open the workout editor; anything else the calendar. */
function viewFromHash(hash: string): View {
  const match = /^#workouts(?:\/(.+))?$/.exec(hash);
  if (!match) return { kind: 'calendar' };
  return { kind: 'workouts', workoutId: match[1] ? decodeURIComponent(match[1]) : null };
}

function hashFor(view: View): string {
  if (view.kind === 'calendar') return '#calendar';
  return view.workoutId ? `#workouts/${encodeURIComponent(view.workoutId)}` : '#workouts';
}

type Notice = { kind: 'conflict' | 'error'; text: string };

const CONFLICT_TEXT = 'Your plan changed in the app or with your coach since this page loaded, so it has been reloaded. Check it, then make your change again.';

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

function Planner({ me, state, reload, onSignedOut }: {
  me: Me;
  state: StateResponse;
  reload: () => Promise<void>;
  onSignedOut: () => void;
}) {
  const [view, setView] = useState<View>(() => viewFromHash(window.location.hash));
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState<Notice | null>(null);
  const [catalog, setCatalog] = useState<Catalog | null>(null);

  useEffect(() => {
    const onHash = () => setView(viewFromHash(window.location.hash));
    window.addEventListener('hashchange', onHash);
    return () => window.removeEventListener('hashchange', onHash);
  }, []);

  // The exercise list is only needed for editing, so it loads with that view.
  useEffect(() => {
    if (view.kind !== 'workouts' || catalog) return;
    setCatalog({ kind: 'loading' });
    fetchExercises()
      .then((exercises) => setCatalog({ kind: 'ready', exercises }))
      .catch((error: unknown) => {
        if (error instanceof SignedOutError) onSignedOut();
        else setCatalog({ kind: 'error' });
      });
  }, [view.kind, catalog, onSignedOut]);

  function go(next: View) {
    window.location.hash = hashFor(next);
    setView(next);
  }

  const write: Write = async (action) => {
    const plan = state.plan;
    setBusy(true);
    setNotice(null);
    try {
      let at: Reviewed;
      if (plan) {
        at = { planId: plan.id, version: plan.version };
      } else {
        // A new account has no plan yet; its first workout starts one.
        const started = await planWrites.startPlan();
        at = { planId: started.plan.id, version: started.plan.version };
      }
      await action(at);
    } catch (error) {
      if (error instanceof SignedOutError) {
        onSignedOut();
      } else if (isVersionConflict(error)) {
        setNotice({ kind: 'conflict', text: CONFLICT_TEXT });
        await reload().catch(() => undefined);
      } else if (error instanceof ApiError && error.status === 409) {
        // A date or workout changed elsewhere (a session started, another
        // device chose a different workout): show the latest before retrying.
        setNotice({ kind: 'conflict', text: describeWriteError(error.body) });
        await reload().catch(() => undefined);
      } else {
        setNotice({ kind: 'error', text: error instanceof ApiError ? describeWriteError(error.body) : 'That change didn’t save. Check your connection and try again.' });
      }
      setBusy(false);
      return false;
    }
    try {
      await reload();
    } catch {
      setNotice({ kind: 'error', text: 'Saved, but the plan couldn’t be refreshed. Reload the page to see it.' });
    }
    setBusy(false);
    return true;
  };

  return (
    <div className="shell">
      <header className="topbar">
        <div className="brand"><img src="/assets/app-icon.png" alt="" width={32} height={32} /><span className="wordmark">Très Fort</span></div>
        <nav className="views" aria-label="Views">
          <a href="#calendar" aria-current={view.kind === 'calendar' ? 'page' : undefined}>Calendar</a>
          <a href="#workouts" aria-current={view.kind === 'workouts' ? 'page' : undefined}>Workouts</a>
        </nav>
        <div className="account">
          <span className="muted">{me.display_name ?? me.email ?? 'Signed in'}</span>
          <button type="button" className="ghost" onClick={async () => { await signOut(); onSignedOut(); }}>Sign out</button>
        </div>
      </header>
      {notice && (
        <div className={`notice ${notice.kind}`} role="alert">
          <p>{notice.text}</p>
          <button type="button" className="ghost small" onClick={() => setNotice(null)}>Dismiss</button>
        </div>
      )}
      {view.kind === 'workouts' ? (
        <WorkoutsPage
          workouts={state.plan?.workouts ?? []}
          version={state.plan?.version ?? 0}
          selectedId={view.workoutId}
          onSelect={(workoutId) => go({ kind: 'workouts', workoutId })}
          write={write}
          busy={busy}
          catalog={catalog ?? { kind: 'loading' }}
          miles={prefersMiles()}
        />
      ) : (
        <CalendarView state={state} write={write} busy={busy} onEditWorkout={(workoutId) => go({ kind: 'workouts', workoutId })} />
      )}
    </div>
  );
}

function CalendarView({ state, write, busy, onEditWorkout }: {
  state: StateResponse;
  write: Write;
  busy: boolean;
  onEditWorkout: (id: string | null) => void;
}) {
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
  const cellFor = useCallback(
    (date: string) => cells.get(date) ?? (inputs ? projectRange(inputs, date, date, today).get(date) : undefined),
    [cells, inputs, today],
  );
  const selectedCell = useMemo(() => cellFor(selected), [cellFor, selected]);
  const workouts = useMemo(() => new Map((plan?.workouts ?? []).map((w) => [w.id, w])), [plan]);
  const loads = useMemo(() => activityLoads(state), [state]);
  const sports = useMemo(() => activitySports(state), [state]);
  const routable = useMemo(() => routableActivityIds(state), [state]);

  return (
    <>
      {!plan ? (
        <main className="centered">
          <h1>No plan yet</h1>
          <p className="muted">Build your first workout here, or pick a starter workout in the iPhone app.</p>
          <button type="button" onClick={() => onEditWorkout(null)}>Build a workout</button>
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
                      sports={sports}
                      onSelect={() => setSelected(date)}
                    />
                  ))}
                </div>
              ))}
            </div>
            <RoutineEditor schedule={plan.schedule} workouts={plan.workouts} write={write} busy={busy} />
            <AwayDates trips={plan.trips ?? []} today={today} version={plan.version} write={write} busy={busy} />
          </section>

          <DayDetail
            date={selected}
            cell={selectedCell}
            workout={workoutFor(selectedCell, workouts)}
            trip={tripOn(selected, plan.trips ?? [])}
            miles={miles}
            loads={loads}
            sports={sports}
            routable={routable}
            onEditWorkout={onEditWorkout}
            actions={(
              <DateActions date={selected} today={today} cell={selectedCell} workout={workoutFor(selectedCell, workouts)}
                state={state} cellFor={cellFor} write={write} busy={busy} />
            )}
          />
        </main>
      )}
    </>
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
  sports: Map<string, string>;
  onSelect: () => void;
}) {
  const { date, cell, workout, inMonth, isToday, isSelected, sports, onSelect } = props;
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
          {itemTitle(item, sports)}
        </span>
      ))}
    </button>
  );
}

function DayDetail(props: {
  date: string;
  cell: CalendarCell | undefined;
  workout: Workout | undefined;
  trip: ReturnType<typeof tripOn>;
  miles: boolean;
  loads: Map<string, ShownLoad | null>;
  sports: Map<string, string>;
  /** Completed activities that may have a route. */
  routable: Set<string>;
  onEditWorkout: (id: string) => void;
  actions: ReactNode;
}) {
  const { date, cell, workout, trip, miles, loads, sports, routable, onEditWorkout, actions } = props;
  return (
    <aside className="detail" aria-labelledby="detail-title">
      <h2 id="detail-title">{formatLongDate(date)}</h2>
      <p className="status-line">{cell ? STATUS_LABELS[cell.status] : 'Nothing recorded'}</p>
      {actions}
      {trip && (
        <div className="note">
          <strong>Away</strong> {trip.start} to {trip.end}
          {trip.can_train_light ? ', light training possible' : ''}
          {trip.note ? <p className="muted">{trip.note}</p> : null}
        </div>
      )}
      {workout && cell?.status !== 'rest' && cell?.status !== 'unavailable' && (
        <section>
          <div className="section-head">
            <h3>{workout.name}</h3>
            <button type="button" className="ghost small" onClick={() => onEditWorkout(workout.id)}>Edit workout</button>
          </div>
          {workout.notes ? <p className="muted">{workout.notes}</p> : null}
          <ol className="slots">
            {slotBlocks(workout).map((block) => block.group ? (
              <li key={block.members[0]!.id} className="group-block">
                <div className="group-head">
                  <strong>{block.group.title}</strong>
                  <span className="muted">{describeGroup(block.group)}</span>
                </div>
                <ol className="slots">
                  {block.members.map((slot) => <SlotItem key={slot.id} slot={slot} miles={miles} />)}
                </ol>
              </li>
            ) : (
              <SlotItem key={block.members[0]!.id} slot={block.members[0]!} miles={miles} />
            ))}
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
              const title = itemTitle(item, sports);
              return (
                <li key={item.id}>
                  <div className="slot-name">{title}</div>
                  <div className="muted">
                    {itemType(item, sports)} · {item.completed ? 'Done' : 'Planned'}
                    {item.planned_duration_sec ? ` · ${formatClock(item.planned_duration_sec)}` : ''}
                    {load ? ` · load ${Math.round(load.load)}${method ? ` (${method})` : ''}` : ''}
                  </div>
                  {item.completed && routable.has(item.id) ? <RouteMap activityId={item.id} label={`Route of ${title}`} /> : null}
                </li>
              );
            })}
          </ul>
        </section>
      ) : null}
      {!workout && !cell?.items.length && !trip ? <p className="muted">A rest day.</p> : null}
    </aside>
  );
}

function SlotItem({ slot, miles }: { slot: Slot; miles: boolean }) {
  const steps = describeRunSteps(slot.run_steps, miles);
  return (
    <li className={slot.is_warmup ? 'warmup' : ''}>
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
}
