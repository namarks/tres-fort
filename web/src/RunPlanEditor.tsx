import { useEffect, useId, useMemo, useRef, useState, type FormEvent, type ReactNode } from 'react';
import { RUN_STEP_LIMITS, type RunPlanItem } from '../../src/runSteps';
import { describeRunSteps, type Slot } from './model';
import {
  DISTANCE_UNITS,
  STEP_KINDS,
  draftFromRunSteps,
  moved,
  newRepeat,
  newStep,
  partName,
  runStepsFromDraft,
  sameRunSteps,
  stepFromDraft,
  type DistanceUnit,
  type ItemDraft,
  type StepDraft,
  type TargetChoice,
} from './runPlan';

/**
 * Plans a run's steps (the app's RunPlanEditorView): a warm-up, a repeat for
 * intervals, each step ending after a time or a distance with an optional
 * pace or heart rate range. Saves through the slot route like any other edit.
 */
export function RunPlanEditor(props: {
  slot: Slot;
  miles: boolean;
  busy: boolean;
  onSave: (steps: RunPlanItem[] | null) => void;
  onCancel: () => void;
}) {
  const { slot, miles, busy, onSave, onCancel } = props;
  const initial = useMemo(() => draftFromRunSteps(slot.run_steps, miles), [slot.run_steps, miles]);
  const [items, setItems] = useState<ItemDraft[]>(initial ?? []);
  const [showErrors, setShowErrors] = useState(false);
  const formRef = useRef<HTMLFormElement>(null);
  useEffect(() => formRef.current?.querySelector<HTMLElement>('select, input, button')?.focus(), []);
  const result = useMemo(() => runStepsFromDraft(items, miles), [items, miles]);
  const unchanged = result.ok && sameRunSteps(slot.run_steps, result.items);
  const preview = result.ok && result.items ? describeRunSteps(JSON.stringify(result.items), miles) : [];
  const per = miles ? 'mi' : 'km';

  const updateItem = (id: string, patch: Partial<ItemDraft>) =>
    setItems((current) => current.map((item) => (item.id === id ? { ...item, ...patch } : item)));
  const updateStep = (id: string, patch: Partial<StepDraft>) =>
    setItems((current) => current.map((item) => ({
      ...item,
      steps: item.steps.map((step) => (step.id === id ? { ...step, ...patch } : step)),
    })));
  // Removing a repeat's last step removes the repeat, as in the app.
  const removeStep = (itemId: string, stepId: string) =>
    setItems((current) => current.flatMap((item) => {
      if (item.id !== itemId) return [item];
      const steps = item.steps.filter((step) => step.id !== stepId);
      return item.repeats !== null && steps.length ? [{ ...item, steps }] : [];
    }));

  if (initial === null) {
    return (
      <div className="panel run-plan" role="group" aria-label={`Plan ${slot.exercise_name}`}>
        <p>This run’s steps use a format the web app can’t edit yet. Remove them to plan the run again here, or edit them in the iPhone app.</p>
        <div className="form-actions">
          <button type="button" className="danger-fill" disabled={busy} onClick={() => onSave(null)}>Remove all steps</button>
          <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
        </div>
      </div>
    );
  }

  function submit(event: FormEvent) {
    event.preventDefault();
    if (!result.ok) return setShowErrors(true);
    if (unchanged) return onCancel();
    onSave(result.items);
  }

  const canAddPart = items.length < RUN_STEP_LIMITS.items;

  return (
    <form ref={formRef} className="panel run-plan" onSubmit={submit} noValidate aria-label={`Plan ${slot.exercise_name}`}>
      <h3>Plan this run</h3>
      {items.length === 0 && (
        <p className="muted">
          No steps yet, so this is a run at your own pace. Add steps such as a warm-up, then a repeat for intervals,
          each with an optional pace or heart rate range.
        </p>
      )}
      <ol className="run-parts">
        {items.map((item, index) => {
          const name = partName(items, index, null);
          const order = (
            <span className="row-actions">
              <button type="button" className="icon" disabled={index === 0} onClick={() => setItems(moved(items, item.id, -1))} aria-label={`Move ${name.toLowerCase()} up`}>↑</button>
              <button type="button" className="icon" disabled={index === items.length - 1} onClick={() => setItems(moved(items, item.id, 1))} aria-label={`Move ${name.toLowerCase()} down`}>↓</button>
              <button type="button" className="ghost small danger" onClick={() => setItems(items.filter((other) => other.id !== item.id))}>
                {item.repeats === null ? 'Remove step' : 'Remove repeat'}
              </button>
            </span>
          );
          if (item.repeats === null) {
            const step = item.steps[0]!;
            return (
              <li key={item.id} className="run-part">
                <StepFields step={step} label={name} miles={miles} per={per} showError={showErrors}
                  onChange={(patch) => updateStep(step.id, patch)} actions={order} />
              </li>
            );
          }
          return (
            <li key={item.id} className="run-part repeat">
              <div className="repeat-head">
                <label className="repeat-count">
                  {name}
                  <input inputMode="numeric" value={item.repeats} aria-label={`${name}: times`}
                    onChange={(e) => updateItem(item.id, { repeats: e.target.value })} />
                  <span className="muted">times</span>
                </label>
                {order}
              </div>
              <ol>
                {item.steps.map((step, stepIndex) => {
                  const stepName = partName(items, index, stepIndex);
                  return (
                    <li key={step.id}>
                      <StepFields step={step} label={stepName} miles={miles} per={per} showError={showErrors}
                        onChange={(patch) => updateStep(step.id, patch)}
                        actions={(
                          <span className="row-actions">
                            <button type="button" className="icon" disabled={stepIndex === 0}
                              onClick={() => updateItem(item.id, { steps: moved(item.steps, step.id, -1) })}
                              aria-label={`Move ${stepName.toLowerCase()} up`}>↑</button>
                            <button type="button" className="icon" disabled={stepIndex === item.steps.length - 1}
                              onClick={() => updateItem(item.id, { steps: moved(item.steps, step.id, 1) })}
                              aria-label={`Move ${stepName.toLowerCase()} down`}>↓</button>
                            <button type="button" className="ghost small danger" onClick={() => removeStep(item.id, step.id)}
                              aria-label={`Remove ${stepName.toLowerCase()}`}>Remove</button>
                          </span>
                        )} />
                    </li>
                  );
                })}
              </ol>
              <button type="button" className="ghost small" disabled={item.steps.length >= RUN_STEP_LIMITS.repeatSteps}
                onClick={() => updateItem(item.id, { steps: [...item.steps, newStep(miles)] })}>
                Add step to {name.toLowerCase()}
              </button>
            </li>
          );
        })}
      </ol>
      <div className="form-actions">
        <button type="button" className="ghost" disabled={!canAddPart}
          onClick={() => setItems([...items, { id: crypto.randomUUID(), repeats: null, steps: [newStep(miles)] }])}>Add step</button>
        <button type="button" className="ghost" disabled={!canAddPart} onClick={() => setItems([...items, newRepeat(miles)])}>Add repeat</button>
      </div>
      <small className="muted">
        Paces are per {miles ? 'mile' : 'kilometer'}. Times read as minutes and seconds (10:00) or hours (1:05:00).
        The recorder says when you’re outside a step’s range.
      </small>

      {preview.length > 0 && (
        <div className="preview">
          <strong>The run</strong>
          <ul className="steps">{preview.map((line, i) => <li key={i}>{line}</li>)}</ul>
        </div>
      )}
      {showErrors && !result.ok && (
        <ul role="alert" className="problem">{result.errors.map((error) => <li key={error}>{error}</li>)}</ul>
      )}
      <div className="form-actions">
        <button type="submit" disabled={busy}>{busy ? 'Saving…' : 'Save steps'}</button>
        {slot.run_steps && (
          <button type="button" className="ghost danger" disabled={busy} onClick={() => onSave(null)}>Remove all steps</button>
        )}
        <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
      </div>
    </form>
  );
}

function StepFields(props: {
  step: StepDraft;
  label: string;
  miles: boolean;
  per: string;
  showError: boolean;
  onChange: (patch: Partial<StepDraft>) => void;
  actions: ReactNode;
}) {
  const { step, label, miles, per, showError, onChange, actions } = props;
  const id = useId();
  const checked = stepFromDraft(step, miles);
  const error = showError && !checked.ok ? checked.error : null;
  return (
    <fieldset className="run-step" aria-describedby={error ? `${id}-error` : undefined}>
      <legend>{label}</legend>
      <div className="run-step-fields">
        <select aria-label={`${label}: kind`} value={step.kind} onChange={(e) => onChange({ kind: e.target.value as StepDraft['kind'] })}>
          {STEP_KINDS.map((option) => <option key={option.kind} value={option.kind}>{option.label}</option>)}
        </select>
        <select aria-label={`${label}: ends after`} value={step.ends} onChange={(e) => onChange({ ends: e.target.value as StepDraft['ends'] })}>
          <option value="time">for a time</option>
          <option value="distance">for a distance</option>
        </select>
        {step.ends === 'time' ? (
          <input className="short" aria-label={`${label}: time`} value={step.time} placeholder="10:00"
            onChange={(e) => onChange({ time: e.target.value })} />
        ) : (
          <span className="inline-fields">
            <input className="short" inputMode="decimal" aria-label={`${label}: distance`} value={step.distance}
              onChange={(e) => onChange({ distance: e.target.value })} />
            <select aria-label={`${label}: distance unit`} value={step.unit} onChange={(e) => onChange({ unit: e.target.value as DistanceUnit })}>
              {DISTANCE_UNITS.map((unit) => <option key={unit} value={unit}>{unit}</option>)}
            </select>
          </span>
        )}
        <select aria-label={`${label}: target`} value={step.target} onChange={(e) => onChange({ target: e.target.value as TargetChoice })}>
          <option value="none">no target</option>
          <option value="pace">pace range</option>
          <option value="heart_rate">heart rate range</option>
        </select>
        {step.target === 'pace' && (
          <span className="range">
            <input className="short" aria-label={`${label}: fastest pace per ${per}`} value={step.fastest} placeholder="4:05"
              onChange={(e) => onChange({ fastest: e.target.value })} />
            <span aria-hidden="true">to</span>
            <input className="short" aria-label={`${label}: slowest pace per ${per}`} value={step.slowest} placeholder="4:20"
              onChange={(e) => onChange({ slowest: e.target.value })} />
            <span className="muted">/{per}</span>
          </span>
        )}
        {step.target === 'heart_rate' && (
          <span className="range">
            <input className="short" inputMode="numeric" aria-label={`${label}: lowest heart rate`} value={step.low}
              onChange={(e) => onChange({ low: e.target.value })} />
            <span aria-hidden="true">to</span>
            <input className="short" inputMode="numeric" aria-label={`${label}: highest heart rate`} value={step.high}
              onChange={(e) => onChange({ high: e.target.value })} />
            <span className="muted">bpm</span>
          </span>
        )}
        {actions}
      </div>
      {error && <p id={`${id}-error`} className="problem">{error}</p>}
    </fieldset>
  );
}
