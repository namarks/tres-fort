# Positioning and open source

Slug: positioning-and-open-source · Status: active · Updated: 2026-11-01 · Theme: platform

## Goal

Present Très Fort as one plan for everything a member trains (lifting, runs,
rides, swims and other activities) with AI as an optional add-on, and publish
the code as an open-source project people can contribute to. The owner chose the
positioning on 2026-11-01: "Everything you train. One plan." Done means the
repository, website, in-app copy and App Store listing all lead with that, and a
cleaned public repository exists with a license, contributor guide and
self-hosting notes, published only after the owner's written approval.

## Phases

- [ ] **P0 — Repository and website copy**
  - README, website home page, AGENTS.md and the DESIGN.md summary lead with one
    plan across disciplines, list Apple Health ahead of intervals.icu, and
    describe AI as optional. The website hero is checked at phone, tablet and
    desktop widths with no horizontal scroll.
  - Website changes go live only with a separate website deploy.
- [ ] **P1 — In-app copy**
  - Onboarding and Profile → Coach wording treats AI as an add-on, without
    changing behavior.
- [ ] **P2 — App Store listing**
  - Subtitle "One plan for all your training", a new description and keywords,
    for the first App Store version that ships the run recorder. Version 1.0
    (build 55) keeps its current listing, because it has no run recorder and is
    already in review.
- [ ] **P3 — Open-source decisions**
  - The owner picks the license (recommended: Apache-2.0 with the name and icon
    kept as trademarks), a fresh public repository or flipping this one
    (recommended: fresh, from a cleaned snapshot), and how far self-hosting is
    supported.
- [ ] **P4 — Public snapshot preparation**
  - Remove family details and personal provider identifiers from docs; move the
    Apple team ID, bundle IDs, Cloudflare IDs and Worker URL into per-deployer
    settings; add LICENSE, NOTICE, CONTRIBUTING, SECURITY, a code of conduct,
    issue and PR templates and SELF-HOSTING; run a dedicated secret scanner over
    the snapshot; CI passes on a private copy.
- [ ] **P5 — Publish**
  - Create the public repository, push the snapshot, enable branch protection
    and first-time-contributor approval for Actions, and re-point the owner's
    Mac, CI checks and project at it.

## Execution frontier

- P0
- P1
- P3

## Dependencies

| Local phase | Relationship | Target | Reason |
|---|---|---|---|
| P2 | gated_by | external:owner-app-store-next-version | The listing changes with the first App Store version after 1.0 that includes the run recorder; 1.0 is in review and must not be pulled. |
| P3 | gated_by | external:owner-open-source-decisions | License, repository and self-hosting choices are the owner's. |
| P5 | gated_by | external:owner-public-repo-approval | Publishing code cannot be undone once cloned; it needs the owner's written yes. |

## Next step

**Now (@agent):** Merge P0's copy. **Owner:** choose the P3 options.

## Notes / open questions

- Apple Health as the default activity source (so members need no intervals.icu
  account) is app work outside this plan: typed-in runs, rides and swims
  currently require intervals.icu, and duplicate merging when both sources are
  connected needs checking with real data.
- A pattern scan of all branches on 2026-11-01 found no committed credentials.
  Personal details were found in docs/MULTISPORT.md, docs/dad-quickstart.md,
  docs/MULTISPORT-M0-spike.md and the mirrored TestFlight feedback issues.
- Keep the Très Fort name as a trademark question for the owner; it is not
  required to open-source.
