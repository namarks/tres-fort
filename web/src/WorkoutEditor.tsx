import { useEffect, useId, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { planWrites, type Reviewed } from './api';
import {
  allowsAssistance,
  draftFromSlot,
  factsOfCatalog,
  factsOfSlot,
  fixedMeasure,
  groupDraft,
  groupKind,
  groupMoveDestination,
  groupValues,
  isRun,
  moveDestination,
  newDraft,
  parseTags,
  prescriptionFields,
  reorderedMembers,
  searchCatalog,
  selectedMembers,
  showsLoad,
  storedGroupValues,
  switchUnit,
  tagsOf,
  workoutMoveDestination,
  type CatalogExercise,
  type ExerciseFacts,
  type GroupDraft,
  type GroupValues,
  type SlotDraft,
  type WeightUnit,
} from './editing';
import { describeGroup, describeRunSteps, describeSlot, slotBlocks, type Slot, type SlotBlock, type Workout } from './model';
import { RunPlanEditor } from './RunPlanEditor';

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
  const move = (workout: Workout, to: number) =>
    write((at) => planWrites.updateWorkout(workout.id, { order_index: to }, at));

  return (
    <main className="workouts">
      <nav className="workout-list" aria-labelledby="workouts-title">
        <h1 id="workouts-title">Workouts</h1>
        <NewWorkoutForm write={write} busy={busy} onCreated={onSelect} />
        <ul>
          {listed.map((workout) => {
            const up = showArchived ? null : workoutMoveDestination(workouts, workout.id, -1);
            const down = showArchived ? null : workoutMoveDestination(workouts, workout.id, 1);
            return (
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
                {!showArchived && active.length > 1 && (
                  <span className="order-actions">
                    <button type="button" className="icon" disabled={busy || up === null} onClick={() => up !== null && move(workout, up)} aria-label={`Move ${workout.name} up`}>↑</button>
                    <button type="button" className="icon" disabled={busy || down === null} onClick={() => down !== null && move(workout, down)} aria-label={`Move ${workout.name} down`}>↓</button>
                  </span>
                )}
              </li>
            );
          })}
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
  | { kind: 'run'; slotId: string }
  | { kind: 'replace'; slotId: string }
  | { kind: 'remove'; slotId: string }
  /** A new group (from selected exercises) or an existing one. */
  | { kind: 'group'; groupId: string; members: Slot[]; existing: boolean };

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
  // Choosing exercises to group: the ids ticked so far, or null when not choosing.
  const [choosing, setChoosing] = useState<ReadonlySet<string> | null>(null);
  // When the plan changes (here, in the app or by the coach), an open form
  // was filled in against the old plan. Close it rather than resend it, so a
  // stale form can never undo a newer change.
  useEffect(() => {
    setPanel(null);
    setChoosing(null);
  }, [version]);
  const blocks = useMemo(() => slotBlocks(workout), [workout]);
  const archived = !!workout.archived_at;
  const tags = tagsOf(workout);
  const close = () => setPanel(null);
  const chosen = choosing ? selectedMembers(workout, choosing) : null;
  // Two single exercises next to each other can start a superset.
  const canGroup = blocks.some((block, index) => !block.group && blocks[index + 1] && !blocks[index + 1]!.group);
  const listRef = useRef<HTMLOListElement>(null);
  const isChoosing = choosing !== null;
  // Keyboard users start choosing at the first exercise that can be grouped.
  useEffect(() => {
    if (isChoosing) listRef.current?.querySelector<HTMLInputElement>('input[type=checkbox]')?.focus();
  }, [isChoosing]);
  const startChoosing = () => {
    setPanel(null);
    setChoosing(new Set());
  };
  const toggle = (slotId: string, on: boolean) => setChoosing((current) => {
    const next = new Set(current ?? []);
    if (on) next.add(slotId);
    else next.delete(slotId);
    return next;
  });

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
    if (panel.kind === 'run') {
      return (
        <RunPlanEditor
          slot={slot}
          miles={miles}
          busy={busy}
          onCancel={close}
          onSave={(steps) => run((at) => planWrites.updateSlot(workout.id, slot.id, { run_steps: steps }, at))}
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
        {slot.group_id ? ' If one exercise is left in its group, it becomes a single exercise again.' : ''}
      </Confirm>
    );
  };

  const single = (slot: Slot) => (
    <SlotRow
      key={slot.id}
      slot={slot}
      miles={miles}
      busy={busy}
      archived={archived}
      move={(direction) => {
        const to = moveDestination(workout, slot.id, direction);
        return to === null ? null : () => run((at) => planWrites.updateSlot(workout.id, slot.id, { order_index: to }, at));
      }}
      onOpen={(kind) => setPanel({ kind, slotId: slot.id })}
      choose={choosing ? { checked: choosing.has(slot.id), onChange: (on) => toggle(slot.id, on) } : undefined}
      panel={slotPanel(slot)}
    />
  );

  // A group member moves within its group; the group's rounds and rests stay.
  const member = (slot: Slot, block: SlotBlock) => (
    <SlotRow
      key={slot.id}
      slot={slot}
      miles={miles}
      busy={busy || !!choosing}
      archived={archived}
      moveLabel="within its group"
      move={(direction) => {
        const members = reorderedMembers(block.members, slot.id, direction);
        return members === null ? null : () => run((at) => planWrites.setGroup(
          workout.id, slot.group_id!, members, storedGroupValues(block.members), at,
        ));
      }}
      onOpen={(kind) => setPanel({ kind, slotId: slot.id })}
      panel={slotPanel(slot)}
    />
  );

  const groupBlock = (block: SlotBlock) => {
    const group = block.group!;
    const groupId = block.members[0]!.group_id!;
    const memberIds = block.members.map((slot) => slot.id);
    const up = groupMoveDestination(workout, groupId, -1);
    const down = groupMoveDestination(workout, groupId, 1);
    const moveGroup = (to: number) => run((at) => planWrites.setGroup(
      workout.id, groupId, memberIds, { ...storedGroupValues(block.members), order_index: to }, at,
    ));
    const editing = panel?.kind === 'group' && panel.existing && panel.groupId === groupId;
    return (
      <li key={groupId} className="group-block">
        <div className="group-head">
          <div>
            <strong>{group.title}</strong>
            <span className="muted">{describeGroup(group)}</span>
          </div>
          {!archived && (
            <div className="row-actions">
              <button type="button" className="icon" disabled={busy || !!choosing || up === null} onClick={() => up !== null && moveGroup(up)} aria-label={`Move ${group.title} up`}>↑</button>
              <button type="button" className="icon" disabled={busy || !!choosing || down === null} onClick={() => down !== null && moveGroup(down)} aria-label={`Move ${group.title} down`}>↓</button>
              <button type="button" className="ghost small" disabled={busy || !!choosing}
                onClick={() => setPanel({ kind: 'group', groupId, members: block.members, existing: true })}
                aria-label={`Edit ${group.title}`}>Edit group</button>
            </div>
          )}
        </div>
        {editing && (
          <GroupForm
            title={`Edit ${group.title}`}
            members={block.members}
            existing
            busy={busy}
            onCancel={close}
            onSubmit={(values) => run((at) => planWrites.setGroup(workout.id, groupId, memberIds, values, at))}
            onUngroup={() => run((at) => planWrites.clearGroup(workout.id, groupId, at))}
          />
        )}
        <ol className="slots">{block.members.map((slot) => member(slot, block))}</ol>
      </li>
    );
  };

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
        <ol ref={listRef} className="slots editable">
          {blocks.map((block) => (block.group ? groupBlock(block) : single(block.members[0]!)))}
        </ol>
      )}

      {!archived && choosing && (
        <div className="panel" role="group" aria-label="Group exercises">
          <p>
            {chosen
              ? `${chosen.map((slot) => slot.exercise_name).join(', ')}: one set of each per round.`
              : 'Tick two or more exercises next to each other that aren’t already in a superset or circuit.'}
          </p>
          <div className="form-actions">
            <button type="button" className="primary" disabled={busy || !chosen}
              onClick={() => {
                if (!chosen) return;
                setChoosing(null);
                setPanel({ kind: 'group', groupId: crypto.randomUUID(), members: chosen, existing: false });
              }}>
              {chosen ? `Make a ${groupKind(chosen.length)}` : 'Make a superset'}
            </button>
            <button type="button" className="ghost" onClick={() => setChoosing(null)}>Cancel</button>
          </div>
        </div>
      )}

      {!archived && panel?.kind === 'group' && !panel.existing && (
        <GroupForm
          title={`New ${groupKind(panel.members.length)}`}
          members={panel.members}
          existing={false}
          busy={busy}
          onCancel={close}
          onSubmit={(values) => run((at) => planWrites.setGroup(workout.id, panel.groupId, panel.members.map((slot) => slot.id), values, at))}
        />
      )}

      {!archived && !choosing && !(panel?.kind === 'group' && !panel.existing) && (
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
            {canGroup && <button type="button" className="ghost" disabled={busy} onClick={startChoosing}>Make a superset or circuit</button>}
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
  /** The move one place up (-1) or down (+1), or null where it can't go. */
  move: (direction: -1 | 1) => (() => void) | null;
  /** Said after "Move <name> up" for a screen reader, e.g. "within its group". */
  moveLabel?: string;
  onOpen: (kind: 'edit' | 'run' | 'replace' | 'remove') => void;
  /** While choosing exercises to group, a tick box replaces the actions. */
  choose?: { checked: boolean; onChange: (on: boolean) => void };
  panel: ReactNode;
}) {
  const { slot, miles, busy, archived, move, moveLabel, onOpen, choose, panel } = props;
  const up = move(-1);
  const down = move(1);
  const run = isRun(factsOfSlot(slot));
  const steps = describeRunSteps(slot.run_steps, miles);
  const name = slot.exercise_name;
  const within = moveLabel ? ` ${moveLabel}` : '';
  return (
    <li className={slot.is_warmup ? 'warmup' : ''}>
      <div className="slot-row">
        {choose && (
          <input type="checkbox" className="choose" checked={choose.checked}
            onChange={(e) => choose.onChange(e.target.checked)} aria-label={`Choose ${name}`} />
        )}
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
        </div>
        {!archived && !choose && (
          <div className="row-actions">
            <button type="button" className="icon" disabled={busy || !up} onClick={() => up?.()} aria-label={`Move ${name} up${within}`}>↑</button>
            <button type="button" className="icon" disabled={busy || !down} onClick={() => down?.()} aria-label={`Move ${name} down${within}`}>↓</button>
            {run
              ? <button type="button" className="ghost small" disabled={busy} onClick={() => onOpen('run')} aria-label={`Plan ${name}`}>Plan run</button>
              : <button type="button" className="ghost small" disabled={busy} onClick={() => onOpen('edit')} aria-label={`Edit ${name}`}>Edit</button>}
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

/** Rounds and rests of a superset or circuit; also where an existing one is ungrouped. */
function GroupForm(props: {
  title: string;
  members: Slot[];
  existing: boolean;
  busy: boolean;
  onSubmit: (values: GroupValues) => void;
  onUngroup?: () => void;
  onCancel: () => void;
}) {
  const { title, members, existing, busy, onSubmit, onUngroup, onCancel } = props;
  const [draft, setDraft] = useState<GroupDraft>(() => groupDraft(members));
  const [errors, setErrors] = useState<string[]>([]);
  const id = useId();
  const formRef = useRef<HTMLFormElement>(null);
  useEffect(() => formRef.current?.querySelector<HTMLInputElement>('input')?.focus(), []);

  function submit(event: FormEvent) {
    event.preventDefault();
    const result = groupValues(draft);
    if (!result.ok) return setErrors(result.errors);
    setErrors([]);
    const stored = groupValues(groupDraft(members));
    const unchanged = stored.ok && JSON.stringify(stored.values) === JSON.stringify(result.values);
    if (existing && unchanged) return onCancel();
    onSubmit(result.values);
  }

  const field = (key: keyof GroupDraft, label: string) => (
    <div className="field small-field">
      <label htmlFor={`${id}-${key}`}>{label}</label>
      <input id={`${id}-${key}`} inputMode="numeric" value={draft[key]}
        onChange={(e) => setDraft((current) => ({ ...current, [key]: e.target.value }))} />
    </div>
  );

  return (
    <form ref={formRef} className="panel group-form" onSubmit={submit} noValidate aria-label={title}>
      <h3>{title}</h3>
      <ol className="member-order">{members.map((slot) => <li key={slot.id}>{slot.exercise_name}</li>)}</ol>
      <div className="field-row">
        {field('rounds', 'Rounds')}
        {field('transitionRest', 'Rest between exercises, seconds')}
        {field('roundRest', 'Rest after each round, seconds')}
      </div>
      <small className="muted">
        Do one set of each exercise per round, resting between exercises and again after the last.
        Each exercise’s own rest is kept in case you ungroup.
      </small>
      {errors.length > 0 && (
        <ul role="alert" className="problem">{errors.map((error) => <li key={error}>{error}</li>)}</ul>
      )}
      <div className="form-actions">
        <button type="submit" disabled={busy}>{busy ? 'Saving…' : existing ? 'Save group' : `Make ${groupKind(members.length)}`}</button>
        {onUngroup && <button type="button" className="ghost" disabled={busy} onClick={onUngroup}>Ungroup</button>}
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
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
