# Positioning (open source deferred)

Slug: positioning-and-open-source · Status: active · Updated: 2026-11-02 · Theme: platform

## Goal

Present Très Fort as one plan for everything a member trains (lifting, runs,
rides, swims and other activities) with AI as an optional add-on. The owner
chose the positioning on 2026-11-01: "Everything you train. One plan." Done
means the repository, website, in-app copy and App Store listing all lead with
that. Open-sourcing was assessed in the same thread and deferred by the owner
on 2026-11-02 (see Notes).

## Phases

- [x] **P0 — Repository and website copy**
  - README, website home page, AGENTS.md and the DESIGN.md summary lead with one
    plan across disciplines, list Apple Health ahead of intervals.icu, and
    describe AI as optional. The website hero is checked at phone, tablet and
    desktop widths with no horizontal scroll.
  - Website changes go live only with a separate website deploy.
  - Merged in PR #296 (main 872e8da), with the hero checked at 390, 800 and
    1280 px. The owner approved the website deploy on 2026-11-01: website
    Worker version 71c1c4c0 serves tresfort.app with the new title and hero;
    the homepage, /privacy and assets return 200 and the email DNS records are
    unchanged. Rollback target 843f44c8.
- [ ] **P1 — In-app copy**
  - Onboarding and Profile → Coach wording treats AI as an add-on, without
    changing behavior.
- [ ] **P2 — App Store listing**
  - Subtitle "One plan for all your training", a new description and keywords,
    for the first App Store version that ships the run recorder. Version 1.0
    (build 55) keeps its current listing, because it has no run recorder and is
    already in review.

## Execution frontier

- P1

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-app-store-next-version | The listing changes with the first App Store version after 1.0 that includes the run recorder; 1.0 is in review and must not be pulled. |

## Next step

**Now (@agent):** P1 in-app copy, so onboarding and Profile → Coach treat AI
as an add-on.

## Notes / open questions

- Apple Health as the default activity source (so members need no intervals.icu
  account) is app work outside this plan: typed-in runs, rides and swims
  currently require intervals.icu, and duplicate merging when both sources are
  connected needs checking with real data.
- Open source, deferred: on 2026-11-02 the owner decided to keep Très Fort
  closed source for now; the repository stays private. The assessment stands
  if this is revisited as its own plan: no committed credentials were found by
  a pattern scan of all branches on 2026-11-01; personal details sit in
  docs/MULTISPORT.md, docs/dad-quickstart.md, docs/MULTISPORT-M0-spike.md and
  the mirrored TestFlight feedback issues; publish a cleaned snapshot as a new
  repository rather than flipping this one; and because the owner wants to earn
  from the app, AGPL-3.0 with a contributor license agreement (or FSL) fits
  better than Apache-2.0. Repository visibility changes only with the owner's
  written approval.
