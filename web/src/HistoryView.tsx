import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ApiError,
  SignedOutError,
  fetchComparison,
  fetchPlanHistory,
  planWrites,
  type StatePlan,
  type StateResponse,
} from './api';
import {
  actorLabel,
  affectedText,
  changeViews,
  operationLabel,
  reasonText,
  type ChangeView,
  type Comparison,
  type HistoryItem,
  type HistoryPage,
} from './history';
import type { Write } from './WorkoutEditor';

type Loaded<T> = { kind: 'loading' } | { kind: 'ready'; value: T } | { kind: 'error'; message: string };

const LOAD_PROBLEM = 'Your plan changes couldn’t be loaded. Check your connection and try again.';

function problemText(error: unknown, fallback: string): string {
  const code = error instanceof ApiError ? (error.body as { error?: unknown } | null)?.error : null;
  if (code === 'snapshot_not_found') return 'That version is no longer saved.';
  if (code === 'plan_changed') return 'Your plan changed while it was being compared. Try again.';
  return fallback;
}

/**
 * Every saved version of the plan, newest first, with who changed it and why
 * (the app's PlanHistoryView). Choosing one compares it with the plan now;
 * restoring it saves it as a new version, so nothing is lost.
 */
export function HistoryView(props: {
  plan: StatePlan | null;
  sessions: StateResponse['sessions'];
  write: Write;
  busy: boolean;
  miles: boolean;
  onSignedOut: () => void;
}) {
  const { plan, sessions, write, busy, miles, onSignedOut } = props;
  const [history, setHistory] = useState<Loaded<HistoryPage>>({ kind: 'loading' });
  const [loadingMore, setLoadingMore] = useState(false);
  const [moreProblem, setMoreProblem] = useState<string | null>(null);
  const [selected, setSelected] = useState<number | null>(null);
  const [comparison, setComparison] = useState<Loaded<Comparison> | null>(null);
  const [confirming, setConfirming] = useState(false);
  // Shown while the plan is still the version the restore made.
  const [done, setDone] = useState<{ from: number; version: number } | null>(null);
  const request = useRef(0);
  const selectedRef = useRef<number | null>(null);
  const panelRef = useRef<HTMLElement>(null);
  const choose = (version: number | null) => {
    selectedRef.current = version;
    setSelected(version);
  };

  const fail = useCallback((error: unknown) => {
    if (error instanceof SignedOutError) onSignedOut();
  }, [onSignedOut]);

  const load = useCallback(() => {
    const ticket = ++request.current;
    setHistory({ kind: 'loading' });
    choose(null);
    setComparison(null);
    setConfirming(false);
    setMoreProblem(null);
    fetchPlanHistory()
      .then((page) => { if (request.current === ticket) setHistory({ kind: 'ready', value: page }); })
      .catch((error: unknown) => {
        fail(error);
        if (request.current === ticket) setHistory({ kind: 'error', message: LOAD_PROBLEM });
      });
  }, [fail]);

  // A new plan version (saved here, in the app or by the coach) starts over:
  // a comparison with an older "now" could restore over a change unseen.
  const planKey = plan ? `${plan.id}:${plan.version}` : null;
  useEffect(() => {
    if (planKey) load();
  }, [planKey, load]);

  if (!plan) {
    return (
      <main className="history">
        <header className="history-head">
          <h1>Plan changes</h1>
          <p className="muted">Changes to your plan show here once you have one. Add a workout to start.</p>
        </header>
      </main>
    );
  }

  const page = history.kind === 'ready' ? history.value : null;

  function compare(version: number) {
    if (!page) return;
    const ticket = request.current;
    choose(version);
    setConfirming(false);
    setComparison({ kind: 'loading' });
    if (window.matchMedia?.('(max-width: 1000px)').matches) {
      requestAnimationFrame(() => panelRef.current?.scrollIntoView({ block: 'start', behavior: 'smooth' }));
    }
    // Only the latest choice shows, and only while the list it came from does.
    const current = () => request.current === ticket && selectedRef.current === version;
    fetchComparison(version, page.current_version)
      .then((result) => {
        if (!current()) return;
        const matches = result.plan_id === page.plan_id && result.from_version === version
          && result.to_version === page.current_version;
        setComparison(matches
          ? { kind: 'ready', value: result }
          : { kind: 'error', message: 'Your plan changed while it was being compared. Try again.' });
      })
      .catch((error: unknown) => {
        fail(error);
        if (current()) setComparison({ kind: 'error', message: problemText(error, LOAD_PROBLEM) });
      });
  }

  async function loadMore() {
    if (!page?.next_before_version) return;
    const ticket = request.current;
    setLoadingMore(true);
    setMoreProblem(null);
    try {
      const older = await fetchPlanHistory(page.next_before_version);
      if (request.current !== ticket) return;
      if (older.plan_id !== page.plan_id) return load();
      setHistory({
        kind: 'ready',
        value: { ...page, items: [...page.items, ...older.items], next_before_version: older.next_before_version },
      });
    } catch (error) {
      fail(error);
      if (request.current === ticket) setMoreProblem('Earlier changes couldn’t be loaded. Try again.');
    } finally {
      if (request.current === ticket) setLoadingMore(false);
    }
  }

  const reviewed = comparison?.kind === 'ready' ? comparison.value : null;

  async function restore() {
    if (!reviewed) return;
    const { plan_id: planId, from_version: from, to_version: version } = reviewed;
    // The version the member compared against, not whatever the page holds now.
    let made: number | null = null;
    const saved = await write(async () => {
      made = (await planWrites.restoreVersion(from, { planId, version })).version;
    });
    setConfirming(false);
    if (saved && made !== null) setDone({ from, version: made });
  }

  const workoutInProgress = sessions.some((session) => session.status === 'in_progress' && session.plan_id === plan.id);

  return (
    <main className="history">
      <header className="history-head">
        <h1>Plan changes</h1>
        <p className="muted">
          Every change to your plan, from the app, the web or your coach, is saved here.
          Compare a saved version with your plan now before restoring it.
        </p>
        {done && done.version === plan.version && (
          <p className="done-note" role="status">
            Version {done.from} is your plan again, saved as version {done.version}. The plan it replaced is still in this list.
          </p>
        )}
      </header>
      <section className="history-list" aria-label="Saved versions">
        {history.kind === 'loading' && <p className="muted" aria-busy="true">Loading plan changes…</p>}
        {history.kind === 'error' && (
          <div role="alert">
            <p className="problem">{history.message}</p>
            <button type="button" className="ghost" onClick={load}>Try again</button>
          </div>
        )}
        {page && page.items.length === 0 && <p className="muted">No saved changes yet.</p>}
        {page && page.items.length > 0 && (
          <ol className="versions">
            {page.items.map((item) => (
              <VersionRow key={item.version} item={item} current={item.version === page.current_version}
                selected={selected} onCompare={compare} />
            ))}
          </ol>
        )}
        {page?.next_before_version != null && (
          <button type="button" className="ghost" disabled={loadingMore} onClick={loadMore}>
            {loadingMore ? 'Loading…' : 'Load earlier changes'}
          </button>
        )}
        {moreProblem && <p className="problem" role="alert">{moreProblem}</p>}
      </section>

      <section ref={panelRef} className="comparison" aria-label="Comparison">
        {comparison === null && (
          <div className="empty-editor">
            <p className="muted">Choose a version to see how it differs from your plan now.</p>
          </div>
        )}
        {comparison?.kind === 'loading' && <p className="muted" aria-busy="true">Comparing version {selected} with your plan now…</p>}
        {comparison?.kind === 'error' && <p className="problem" role="alert">{comparison.message}</p>}
        {reviewed && (
          <ComparisonPanel comparison={reviewed} miles={miles} busy={busy} confirming={confirming}
            blocked={workoutInProgress} onRestore={() => setConfirming(true)} onConfirm={restore}
            onCancel={() => setConfirming(false)} />
        )}
      </section>
    </main>
  );
}

function VersionRow({ item, current, selected, onCompare }: {
  item: HistoryItem;
  current: boolean;
  selected: number | null;
  onCompare: (version: number) => void;
}) {
  const affected = affectedText(item);
  const when = new Date(item.created_at).toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
  const before = item.previous_version;
  const reason = reasonText(item);
  return (
    <li className={selected === item.version ? 'version selected' : 'version'}>
      <div className="version-head">
        <strong>{operationLabel(item.operation)}</strong>
        <span className="tag">{current ? `Version ${item.version} · now` : `Version ${item.version}`}</span>
      </div>
      {reason && <p className="reason">{reason}</p>}
      {affected && <p className="affected">{affected}</p>}
      <p className="muted when">{actorLabel(item.actor)} · {when}</p>
      <div className="version-actions">
        {!current && (
          <button type="button" className="ghost small" aria-pressed={selected === item.version}
            onClick={() => onCompare(item.version)}>Compare with now</button>
        )}
        {before != null && (
          <button type="button" className="ghost small"
            aria-label={`Compare version ${before}, from before this change, with now`}
            onClick={() => onCompare(before)}>Before this change</button>
        )}
      </div>
    </li>
  );
}

const STATUS_TEXT: Record<ChangeView['status'], (version: number) => string> = {
  added: (version) => `New since version ${version}`,
  removed: () => 'Not in your plan now',
  changed: () => 'Changed',
};

function ComparisonPanel(props: {
  comparison: Comparison;
  miles: boolean;
  busy: boolean;
  confirming: boolean;
  blocked: boolean;
  onRestore: () => void;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const { comparison, miles, busy, confirming, blocked, onRestore, onConfirm, onCancel } = props;
  const from = comparison.from_version;
  const views = useMemo(() => changeViews(comparison.changes, miles), [comparison, miles]);
  const confirmRef = useRef<HTMLButtonElement>(null);
  useEffect(() => { if (confirming) confirmRef.current?.focus(); }, [confirming]);
  const count = comparison.changes.length;

  return (
    <div className="comparison-panel">
      <div className="editor-head">
        <div>
          <h2>Version {from} and your plan now</h2>
          <p className="muted" role="status">
            {count === 0
              ? `Version ${from} matches your plan now (version ${comparison.to_version}).`
              : `${count} difference${count === 1 ? '' : 's'} from your plan now (version ${comparison.to_version}).`}
          </p>
        </div>
        {count > 0 && !confirming && (
          <button type="button" className="danger-fill" disabled={busy || blocked} onClick={onRestore}>Restore version {from}</button>
        )}
      </div>
      {blocked && count > 0 && (
        <p className="fine">A workout is in progress in the app. Finish or discard it there before restoring a version.</p>
      )}
      {confirming && (
        <div className="panel confirm" role="group" aria-label={`Restore version ${from}`}>
          <p>
            Restore version {from}? Your plan will match the “Version {from}” column below, saved as a new version.
            Your plan now stays in this list, so you can restore it the same way.
          </p>
          <div className="form-actions">
            <button ref={confirmRef} type="button" className="danger-fill" disabled={busy} onClick={onConfirm}>
              {busy ? 'Restoring…' : 'Restore as a new version'}
            </button>
            <button type="button" className="ghost" onClick={onCancel}>Cancel</button>
          </div>
        </div>
      )}
      {views.map((view) => (
        <article key={view.key} className="change">
          <h3>
            {view.title}
            <span className={`tag ${view.status}`}>{STATUS_TEXT[view.status](from)}</span>
          </h3>
          {view.rows.length === 0 && <p className="muted">This changed in a way the web can’t show in detail yet.</p>}
          {view.rows.length > 0 && (
            <table className="change-table">
              <thead>
                <tr><td /><th scope="col">Version {from}</th><th scope="col">Now</th></tr>
              </thead>
              <tbody>
                {view.rows.map((row) => (
                  <tr key={row.label}>
                    <th scope="row">{row.label}</th>
                    <td>{row.then}</td>
                    <td>{row.now}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          )}
        </article>
      ))}
    </div>
  );
}
