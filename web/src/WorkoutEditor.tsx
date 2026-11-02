import { useEffect, useId, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { planWrites, type Reviewed } from './api';
import {
  allowsAssistance,
  draftFromSlot,
  factsOfCatalog,
  factsOfSlot,
  fixedMeasure,
  isRun,
  moveDestination,
  newDraft,
  parseTags,
  prescriptionFields,
  searchCatalog,
  showsLoad,
  switchUnit,
  tagsOf,
  type CatalogExercise,
  type ExerciseFacts,
  type SlotDraft,
  type WeightUnit,
} from './editing';
import { describeGroup, describeRunSteps, describeSlot, slotBlocks, type Slot, type Workout } from './model';

/** Runs one plan write against the version on screen; true when it saved. */
export type Write = (action: (at: Reviewed) => Promise<unknown>) => Promise<boolean>;

export type Catalog =
  | { kind: 'loading' }
  | { kind: 'error' }
  | { kind: 'ready'; exercises: CatalogExercise[] };

const UNIT_KEY = 'tresfort.weightUnit';

/** The unit a new slot starts in: the member's last choice, else their region's. */
function preferredUnit(miles: boolean): WeightUnit {
  try {
    const saved = localStorage.getItem(UNIT_KEY);
    if (saved === 'lb' || saved === 'kg') return saved;
  } catch {
    // Storage can be unavailable (private windows); fall through.
  }
  return miles ? 'lb' : 'kg';
}

function rememberUnit(unit: WeightUnit) {
  try {
    localStorage.setItem(UNIT_KEY, unit);
  } catch {
    // Not remembering is fine.
  }
}

export function WorkoutsPage(props: {
  workouts: Workout[];
  /** The plan version on screen; a new one closes any open form. */
  version: number;
  selectedId: string | null;
  onSelect: (id: string | null) => void;
  write: Write;
  busy: boolean;
  catalog: Catalog;
  miles: boolean;
}) {
  const { workouts, version, selectedId, onSelect, write, busy, catalog, miles } = props;
  const [showArchived, setShowArchived] = useState(false);
  const active = workouts.filter((workout) => !workout.archived_at);
  const archived = workouts.filter((workout) => workout.archived_at);
  const listed = showArchived ? archived : active;
  const selected = workouts.find((workout) => workout.id === selectedId) ?? null;

  return (
    <main className="workouts">
      <nav className="workout-list" aria-labelledby="workouts-title">
        <h1 id="workouts-title">Workouts</h1>
        <NewWorkoutForm write={write} busy={busy} onCreated={onSelect} />
        <ul>
          {listed.map((workout) => (
            <li key={workout.id}>
              <button
                type="button"
                className="workout-link"
                aria-current={workout.id === selectedId ? 'page' : undefined}
                onClick={() => onSelect(workout.id)}
              >
                <span>{workout.name}</span>
                <span className="muted">{exerciseCount(workout)}</span>
              </button>
            </li>
          ))}
        </ul>
        {listed.length === 0 && (
          <p className="muted">{showArchived ? 'No archived workouts.' : 'No workouts yet. Name one above to start.'}</p>
        )}
        {(archived.length > 0 || showArchived) && (
          <button type="button" className="ghost small" onClick={() => setShowArchived(!showArchived)}>
            {showArchived ? 'Show workouts' : `Show archived (${archived.length})`}
          </button>
        )}
      </nav>
      <section className="editor" aria-live="polite">
        {selected ? (
          <WorkoutEditor key={selected.id} workout={selected} version={version} write={write} busy={busy} catalog={catalog} miles={miles} onRemoved={() => onSelect(null)} />
        ) : (
          <div className="empty-editor">
            <p className="muted">Choose a workout to edit its exercises, or name a new one.</p>
          </div>
        )}
      </section>
    </main>
  );
}

function exerciseCount(workout: Workout): string {
  const count = workout.exercises.length;
  return count === 1 ? '1 exercise' : `${count} exercises`;
}

function NewWorkoutForm({ write, busy, onCreated }: { write: Write; busy: boolean; onCreated: (id: string) => void }) {
  const [name, setName] = useState('');
  const inputId = useId();

  async function submit(event: FormEvent) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return;
    let created: string | null = null;
    const saved = await write(async (at) => {
      created = (await planWrites.addWorkout(trimmed, at)).id;
    });
    if (saved && created) {
      setName('');
      onCreated(created);
    }
  }

  return (
    <form className="new-workout" onSubmit={submit}>
      <label htmlFor={inputId}>New workout</label>
      <div className="inline-fields">
        <input id={inputId} value={name} onChange={(e) => setName(e.target.value)} placeholder="Name, e.g. Upper body" maxLength={80} />
        <button type="submit" disabled={busy || !name.trim()}>Add</button>
      </div>
    </form>
  );
}

type Panel =
  | { kind: 'details' }
  | { kind: 'archive' }
  | { kind: 'delete' }
  | { kind: 'add'; warmup: boolean; exercise: CatalogExercise | null }
  | { kind: 'edit'; slotId: string }
  | { kind: 'replace'; slotId: string }
  | { kind: 'remove'; slotId: string };

function WorkoutEditor(props: {
  workout: Workout;
  version: number;
  write: Write;
  busy: boolean;
  catalog: Catalog;
  miles: boolean;
  onRemoved: () => void;
}) {
  const { workout, version, write, busy, catalog, miles, onRemoved } = props;
  const [panel, setPanel] = useState<Panel | null>(null);
  // When the plan changes (here, in the app or by the coach), an open form
  // was filled in against the old plan. Close it rather than resend it, so a
  // stale form can never undo a newer change.
  useEffect(() => setPanel(null), [version]);
  const blocks = useMemo(() => slotBlocks(workout), [workout]);
  const archived = !!workout.archived_at;
  const tags = tagsOf(workout);
  const close = () => setPanel(null);

  async function run(action: (at: Reviewed) => Promise<unknown>, after?: () => void) {
    if (await write(action)) {
      close();
      after?.();
    }
  }

  const slotPanel = (slot: Slot): ReactNode => {
    if (!panel || !('slotId' in panel) || panel.slotId !== slot.id) return null;
    if (panel.kind === 'edit') {
      return (
        <SlotForm
          facts={factsOfSlot(slot)}
          initial={draftFromSlot(slot)}
          editing={slot}
          busy={busy}
          submitLabel="Save targets"
          onCancel={close}
          onSubmit={(fields) => run((at) => planWrites.updateSlot(workout.id, slot.id, fields, at))}
        />
      );
    }
    if (panel.kind === 'replace') {
      return (
        <ExercisePicker
          title={`Replace ${slot.exercise_name}`}
          catalog={catalog}
          exclude={slot.exercise_id}
          busy={busy}
          onCancel={close}
          onPick={(exercise) => run((at) => planWrites.replaceSlot(workout.id, slot.id, exercise.id, at))}
        />
      );
    }
    return (
      <Confirm
        busy={busy}
        action="Remove exercise"
        onCancel={close}
        onConfirm={() => run((at) => planWrites.removeSlot(workout.id, slot.id, at))}
      >
        Remove {slot.exercise_name} from this workout? Sets you already logged stay in your history.
      </Confirm>
    );
  };

  const row = (slot: Slot, movable: boolean) => (
    <SlotRow
      key={slot.id}
      slot={slot}
      miles={miles}
      busy={busy}
      archived={archived}
      up={movable ? moveDestination(workout, slot.id, -1) : null}
      down={movable ? moveDestination(workout, slot.id, 1) : null}
      onMove={(to) => run((at) => planWrites.updateSlot(workout.id, slot.id, { order_index: to }, at))}
      onOpen={(kind) => setPanel({ kind, slotId: slot.id })}
      panel={slotPanel(slot)}
    />
  );

  return (
    <article className="workout-editor" aria-labelledby="workout-title">
      <header className="editor-head">
        <div>
          <h2 id="workout-title">{workout.name}</h2>
          <p className="muted">
            {archived ? 'Archived. Restore it to use it in your routine again.' : 'Edits apply to this saved workout whenever you use it. Completed workouts stay as they were.'}
          </p>
          {tags.length > 0 && <p className="tags">{tags.map((tag) => <span key={tag} className="tag">{tag}</span>)}</p>}
          {workout.notes && <p className="muted">{workout.notes}</p>}
        </div>
        <div className="head-actions">
          <button type="button" className="ghost" disabled={busy} onClick={() => setPanel({ kind: 'details' })}>Rename and tags</button>
          {archived ? (
            <button type="button" className="ghost" disabled={busy} onClick={() => run((at) => planWrites.updateWorkout(workout.id, { archived_at: null }, at))}>Restore</button>
          ) : (
            <button type="button" className="ghost" disabled={busy} onClick={() => setPanel({ kind: 'archive' })}>Archive</button>
          )}
          <button type="button" className="ghost danger" disabled={busy} onClick={() => setPanel({ kind: 'delete' })}>Delete</button>
        </div>
      </header>

      {panel?.kind === 'details' && (
        <DetailsForm workout={workout} busy={busy} onCancel={close} onSubmit={(fields) => run((at) => planWrites.updateWorkout(workout.id, fields, at))} />
      )}
      {panel?.kind === 'archive' && (
        <Confirm busy={busy} action="Archive workout" onCancel={close}
          onConfirm={() => run((at) => planWrites.updateWorkout(workout.id, { archived_at: Date.now() }, at))}>
          Archive {workout.name}? Completed workouts and logged sets stay in your history. Weekdays and dates that use it become rest days. You can restore it later.
        </Confirm>
      )}
      {panel?.kind === 'delete' && (
        <Confirm busy={busy} action="Delete workout" onCancel={close}
          onConfirm={() => run((at) => planWrites.deleteWorkout(workout.id, at), onRemoved)}>
          Delete {workout.name}? Past sessions and logged sets stay in your history. Weekdays that use it become rest days.
        </Confirm>
      )}

      {blocks.length === 0 ? (
        <p className="muted">No exercises yet. Add one below.</p>
      ) : (
        <ol className="slots editable">
          {blocks.map((block) => block.group ? (
            <li key={block.members[0]!.id} className="group-block">
              <div className="group-head">
                <strong>{block.group.title}</strong>
                <span className="muted">{describeGroup(block.group)}</span>
              </div>
              <ol className="slots">{block.members.map((slot) => row(slot, false))}</ol>
              <p className="fine">Change a superset’s rounds, rests or order in the iPhone app for now.</p>
            </li>
          ) : row(block.members[0]!, true))}
        </ol>
      )}

      {!archived && (
        panel?.kind === 'add' ? (
          panel.exercise ? (
            <div className="panel">
              <h3>{panel.warmup ? 'Add warm-up' : 'Add exercise'}: {panel.exercise.name}</h3>
              <SlotForm
                facts={factsOfCatalog(panel.exercise)}
                initial={newDraft(factsOfCatalog(panel.exercise), { warmup: panel.warmup, unit: preferredUnit(miles) })}
                busy={busy}
                submitLabel="Add to workout"
                onCancel={close}
                onSubmit={(fields) => {
                  if (typeof fields.target_weight_unit === 'string') rememberUnit(fields.target_weight_unit as WeightUnit);
                  return run((at) => planWrites.addSlot(workout.id, panel.exercise!.id, fields, at));
                }}
              />
            </div>
          ) : (
            <ExercisePicker
              title={panel.warmup ? 'Add warm-up' : 'Add exercise'}
              catalog={catalog}
              busy={busy}
              onCancel={close}
              onPick={(exercise) => setPanel({ ...panel, exercise })}
            />
          )
        ) : (
          <div className="add-actions">
            <button type="button" disabled={busy} onClick={() => setPanel({ kind: 'add', warmup: false, exercise: null })}>Add exercise</button>
            <button type="button" className="ghost" disabled={busy} onClick={() => setPanel({ kind: 'add', warmup: true, exercise: null })}>Add warm-up</button>
          </div>
        )
      )}
    </article>
  );
}

function SlotRow(props: {
  slot: Slot;
  miles: boolean;
  busy: boolean;
  archived: boolean;
  up: number | null;
  down: number | null;
  onMove: (to: number) => void;
  onOpen: (kind: 'edit' | 'replace' | 'remove') => void;
  panel: ReactNode;
}) {
  const { slot, miles, busy, archived, up, down, onMove, onOpen, panel } = props;
  const run = isRun(factsOfSlot(slot));
  const steps = describeRunSteps(slot.run_steps, miles);
  const name = slot.exercise_name;
  return (
    <li className={slot.is_warmup ? 'warmup' : ''}>
      <div className="slot-row">
        <div className="slot-text">
          <div className="slot-name">
            {slot.group_label ? <span className="group">{slot.group_label}</span> : null}
            {name}
            {slot.is_warmup ? <span className="tag">Warm-up</span> : null}
          </div>
          {steps.length ? (
            <ul className="steps">{steps.map((line, i) => <li key={i}>{line}</li>)}</ul>
          ) : (
            <div className="muted">{run ? 'No steps planned' : describeSlot(slot)}</div>
          )}
          {run && <div className="fine">Plan this run’s steps in the iPhone app for now.</div>}
        </div>
        {!archived && (
          <div className="row-actions">
            <button type="button" className="icon" disabled={busy || up === null} onClick={() => up !== null && onMove(up)} aria-label={`Move ${name} up`}>↑</button>
            <button type="button" className="icon" disabled={busy || down === null} onClick={() => down !== null && onMove(down)} aria-label={`Move ${name} down`}>↓</button>
            {!run && <button type="button" className="ghost small" disabled={busy} onClick={() => onOpen('edit')} aria-label={`Edit ${name}`}>Edit</button>}
            {!slot.run_steps && <button type="button" className="ghost small" disabled={busy} onClick={() => onOpen('replace')} aria-label={`Replace ${name}`}>Replace</button>}
            <button type="button" className="ghost small danger" disabled={busy} onClick={() => onOpen('remove')} aria-label={`Remove ${name}`}>Remove</button>
          </div>
        )}
      </div>
      {panel}
    </li>
  );
}

function Confirm(props: { children: ReactNode; action: string; busy: boolean; onConfirm: () => void; onCancel: () => void }) {
  // Focus starts on the safe choice, so Enter alone never deletes anything.
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

function DetailsForm(props: {
  workout: Workout;
  busy: boolean;
  onSubmit: (fields: Record<string, unknown>) => void;
  onCancel: () => void;
}) {
  const { workout, busy, onSubmit, onCancel } = props;
  const [name, setName] = useState(workout.name);
  const [tags, setTags] = useState(tagsOf(workout).join(', '));
  const [notes, setNotes] = useState(workout.notes ?? '');
  const [error, setError] = useState<string | null>(null);
  const ids = { name: useId(), tags: useId(), notes: useId() };

  function submit(event: FormEvent) {
    event.preventDefault();
    const trimmed = name.trim();
    if (!trimmed) return setError('Give the workout a name.');
    const parsed = parseTags(tags);
    if (!parsed.ok) return setError(parsed.error);
    const fields: Record<string, unknown> = {};
    if (trimmed !== workout.name) fields.name = trimmed;
    if (parsed.tags.join(',') !== tagsOf(workout).join(',')) fields.tags = parsed.tags;
    const nextNotes = notes.trim() ? notes.trim() : null;
    if (nextNotes !== (workout.notes ?? null)) fields.notes = nextNotes;
    if (Object.keys(fields).length === 0) return onCancel();
    onSubmit(fields);
  }

  return (
    <form className="panel" onSubmit={submit}>
      <div className="field">
        <label htmlFor={ids.name}>Name</label>
        <input id={ids.name} value={name} onChange={(e) => setName(e.target.value)} maxLength={80} autoFocus />
      </div>
      <div className="field">
        <label htmlFor={ids.tags}>Tags</label>
        <input id={ids.tags} value={tags} onChange={(e) => setTags(e.target.value)} placeholder="Separate with commas, e.g. travel, upper" aria-describedby={`${ids.tags}-hint`} />
        <small id={`${ids.tags}-hint`} className="muted">When you pick a workout for an away date in the app, ones tagged travel are listed first.</small>
      </div>
      <div className="field">
        <label htmlFor={ids.notes}>Notes</label>
        <textarea id={ids.notes} value={notes} onChange={(e) => setNotes(e.target.value)} rows={3} />
      </div>
      {error && <p role="alert" className="problem">{error}</p>}
      <div className="form-actions">
        <button type="submit" disabled={busy}>Save</button>
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}

export function ExercisePicker(props: {
  title: string;
  catalog: Catalog;
  exclude?: string;
  busy: boolean;
  onPick: (exercise: CatalogExercise) => void;
  onCancel: () => void;
}) {
  const { title, catalog, exclude, busy, onPick, onCancel } = props;
  const [query, setQuery] = useState('');
  const searchId = useId();
  const matches = useMemo(
    () => catalog.kind === 'ready' ? searchCatalog(catalog.exercises.filter((e) => e.id !== exclude), query) : [],
    [catalog, exclude, query],
  );
  return (
    <div className="panel picker">
      <h3>{title}</h3>
      <label htmlFor={searchId}>Search exercises</label>
      <input id={searchId} type="search" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Name, alias or muscle" autoFocus />
      {catalog.kind === 'loading' && <p className="muted">Loading exercises…</p>}
      {catalog.kind === 'error' && <p role="alert" className="problem">The exercise list couldn’t be loaded. Refresh to try again.</p>}
      {catalog.kind === 'ready' && (
        matches.length ? (
          <ul className="matches">
            {matches.map((exercise) => (
              <li key={exercise.id}>
                <button type="button" disabled={busy} onClick={() => onPick(exercise)}>
                  <span>{exercise.name}</span>
                  <span className="muted">{exercise.primary_muscle} · {MODALITY_LABELS[exercise.modality] ?? exercise.modality}</span>
                </button>
              </li>
            ))}
          </ul>
        ) : <p className="muted">No exercises match.</p>
      )}
      <div className="form-actions">
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

const MODALITY_LABELS: Record<string, string> = {
  barbell: 'barbell', dumbbell: 'dumbbell', bw: 'bodyweight', timed: 'hold', cardio: 'cardio',
  machine: 'machine', kettlebell: 'kettlebell', band: 'band',
};

function SlotForm(props: {
  facts: ExerciseFacts;
  initial: SlotDraft;
  editing?: Slot;
  busy: boolean;
  submitLabel: string;
  onSubmit: (fields: Record<string, unknown>) => void;
  onCancel: () => void;
}) {
  const { facts, initial, editing, busy, submitLabel, onSubmit, onCancel } = props;
  const [draft, setDraft] = useState(initial);
  const [errors, setErrors] = useState<string[]>([]);
  const id = useId();
  const formRef = useRef<HTMLFormElement>(null);
  // Keyboard users land in the form that just opened.
  useEffect(() => formRef.current?.querySelector<HTMLInputElement>('input:not([disabled])')?.focus(), []);
  const set = (patch: Partial<SlotDraft>) => setDraft((current) => ({ ...current, ...patch }));
  const fixed = fixedMeasure(facts.modality);
  const measure = fixed ?? draft.measure;
  const grouped = !!editing?.group_id;
  const perSide = facts.laterality === 'unilateral' ? ' per side' : '';
  const assistance = allowsAssistance(facts.modality);

  function submit(event: FormEvent) {
    event.preventDefault();
    const result = prescriptionFields(draft, facts, editing);
    if (!result.ok) return setErrors(result.errors);
    setErrors([]);
    if (Object.keys(result.fields).length === 0) return onCancel();
    onSubmit(result.fields);
  }

  const number = (key: keyof SlotDraft, label: string, options: { disabled?: boolean } = {}) => (
    <div className="field small-field">
      <label htmlFor={`${id}-${key}`}>{label}</label>
      <input
        id={`${id}-${key}`}
        inputMode="decimal"
        value={draft[key] as string}
        disabled={options.disabled}
        onChange={(e) => set({ [key]: e.target.value } as Partial<SlotDraft>)}
      />
    </div>
  );

  return (
    <form ref={formRef} className="panel slot-form" onSubmit={submit} noValidate>
      <label className="check">
        <input type="checkbox" checked={draft.isWarmup} onChange={(e) => set({ isWarmup: e.target.checked })} />
        Warm-up <span className="muted">(kept out of working-set totals and session intensity)</span>
      </label>

      {!fixed && (
        <fieldset className="segmented">
          <legend>Measure</legend>
          <label><input type="radio" name={`${id}-measure`} checked={measure === 'reps'} onChange={() => set({ measure: 'reps' })} /> Reps</label>
          <label><input type="radio" name={`${id}-measure`} checked={measure === 'hold'} onChange={() => set({ measure: 'hold' })} /> Hold</label>
        </fieldset>
      )}

      <div className="field-row">
        {number('sets', grouped ? 'Rounds (set on the group)' : 'Sets', { disabled: grouped })}
        {measure === 'reps' && number('reps', draft.useRange ? `Reps, at least${perSide}` : `Reps${perSide}`)}
        {measure === 'reps' && draft.useRange && number('repsMax', `Up to${perSide}`)}
        {measure === 'hold' && number('holdSeconds', 'Seconds each')}
        {measure === 'duration' && number('minutes', 'Minutes')}
      </div>
      {measure === 'reps' && (
        <label className="check">
          <input type="checkbox" checked={draft.useRange} onChange={(e) => set({ useRange: e.target.checked })} />
          Rep range
        </label>
      )}

      {showsLoad(facts.modality) && (
        <div className="field-row">
          <div className="field small-field">
            <label htmlFor={`${id}-weight`}>Weight{facts.loadMode === 'per_hand' ? ', each hand' : ''}</label>
            <div className="inline-fields">
              <input id={`${id}-weight`} inputMode="decimal" value={draft.weight} placeholder="No target"
                aria-describedby={`${id}-weight-hint`} onChange={(e) => set({ weight: e.target.value })} />
              <select aria-label="Weight unit" value={draft.unit} onChange={(e) => setDraft(switchUnit(draft, e.target.value as WeightUnit))}>
                <option value="lb">lb</option>
                <option value="kg">kg</option>
              </select>
            </div>
          </div>
          {number('rpe', 'Target RPE')}
        </div>
      )}
      {showsLoad(facts.modality) && (
        <small id={`${id}-weight-hint`} className="muted">
          {assistance
            ? 'Enter 0 for bodyweight, added load as a positive number and assistance as a negative one. Leave it empty to start from your last set.'
            : 'Each set starts at this weight. Leave it empty to start from your last set. RPE is optional, from 1 to 10.'}
        </small>
      )}

      <div className="field-row">
        {number('rest', grouped ? 'Rest (set on the group)' : 'Rest between sets, seconds', { disabled: grouped })}
      </div>

      {errors.length > 0 && (
        <ul role="alert" className="problem">{errors.map((error) => <li key={error}>{error}</li>)}</ul>
      )}
      <div className="form-actions">
        <button type="submit" disabled={busy}>{busy ? 'Saving…' : submitLabel}</button>
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}
