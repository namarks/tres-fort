# docs/initiatives — Plans of Plans

Initiatives define a bounded mission across canonical engineering workstreams.
They select, order, and prioritize plan nodes, but never copy phase status or
override a member plan's dependency, gate, pause, evidence requirement, or
execution authority. The plan bundles in [`docs/plans`](../plans/README.md)
remain authoritative.

Create `docs/initiatives/<slug>.md` only after every scope reference resolves to
a canonical current plan or phase. Use this structure:

```markdown
# <Initiative title>

Slug: <slug> · Status: active · Updated: <YYYY-MM-DD>

## Objective

<The cross-plan outcome this initiative coordinates.>

## Scope

- plan:<first-workstream>#<phase>
- plan:<second-workstream>

## Priority policy

1. <Intentional ordering not already expressed by dependencies.>

## Completion condition

<Evidence that makes the initiative complete.>

## Stop rules

- Stop at external, product, production, privacy, security, spend, credential,
  or owner-decision gates.
- Stop when no selected node is ready or canonical state has drifted.
```

Scope entries are exact node references; do not use ranges or prose selectors.
Initiative order breaks safe scheduling ties but cannot make blocked work ready.
An initiative grants no implementation, publication, merge, deployment,
production, or external-closeout authority by itself.
