# Public plugin submission worksheet

Prepared for review; not submitted or published. The mobile implementation
must be released and verified before claiming iPhone support in the listing.

## Listing draft

| Field | Prepared value |
|---|---|
| Name | Très Fort |
| Publisher | Nicholas Marks; select the matching owner-verified identity in the portal |
| Short description | Plan training with your workout history. |
| Long description | Connect your Très Fort account to review training, adapt workouts and save plan changes. Conversations stay in your AI app. Uses your existing supported AI account or subscription; Très Fort does not supply model usage. |
| Category | Productivity, subject to the portal's available fitness category |
| Logo | `assets/icon.png`, the existing Très Fort app icon |
| Website | https://tresfort.app |
| Support | `nick@tresfort.app`, linked on the website; use https://tresfort.app/privacy if an HTTPS support URL is required |
| Privacy | https://tresfort.app/privacy |
| Terms | **Draft prepared at [terms-draft.md](terms-draft.md), as requested.** Review and approve before publishing; then add the verified public URL to the manifest and portal. The draft is not effective terms. |
| Release notes | Initial external-AI coaching integration: account-scoped training reads and edits, coaching brief, explicit OAuth consent, and disconnect controls. |
| Availability | **Owner selected all countries supported by the provider.** Use its current supported-country list; legal eligibility and portal attestations still require review. |

The three starter prompts are in `.codex-plugin/plugin.json`. They request
ordinary training organization and review, not diagnosis or treatment.

## Connection configuration

- Submission type: **With MCP**, fixed **Universal** endpoint:
  `https://tres-fort.nmarkspdx.workers.dev/mcp`.
- Authentication: OAuth authorization code, PKCE S256, public client (`none`),
  dynamic client registration. One scope, `mcp`, permits the disclosed training
  reads and writes. The accepted resource is the endpoint above.
- Protected resource discovery:
  `https://tres-fort.nmarkspdx.workers.dev/.well-known/oauth-protected-resource`.
- Authorization server discovery:
  `https://tres-fort.nmarkspdx.workers.dev/.well-known/oauth-authorization-server`.
- Use the redirect URI issued/registered by the provider. No fabricated callback
  or install URL. RFC 9207 stable-callback support is not advertised; use the
  provider's client-specific callback. No OIDC email/domain restriction support
  is advertised; this version does not claim Enterprise domain enforcement.
- Keep the existing connect-code form available for desktop users and provider
  reviewers. On iPhone, a valid HTTPS callback can use app approval instead.
- No static owner bearer or real member health data belongs in the portal,
  listing, screenshots, logs, test cases, or this repository.

## Tool annotation justification

`tools/list` includes all three required annotations for every tool. The
`write` contract already controls auditing. Reads have `readOnlyHint: true` and
`destructiveHint: false`. Audited actions have `readOnlyHint: false`.

Append-only operations (`add_note`, `log_activity`, `add_exercise`,
`add_workout` and its `add_day` alias) have `destructiveHint: false`: they add
records rather than erase existing training. Other writes advertise
`destructiveHint: true` because they may replace prescriptions, correct values,
remove/soft-delete data, change scheduling or reconcile imported caches. That
includes restore operations and modifications that remain visible in history.
`log_set` is also potentially destructive: reopening a discarded legacy session
can clear its old assignment and feedback. `refresh_rides` is an action that refreshes a cache, not a read-only query.

All tools have `openWorldHint: false`: destinations are the authenticated
account's training data, fixed exercise catalog, authorized groups or linked
Intervals.icu account. No tool accepts arbitrary network destinations or
publishes publicly. These hints inform host confirmation; they do not replace
explicit account consent, host write approval, tenant checks or version checks.

## Review account and release steps

1. Owner verifies individual/business identity and Apps Management write access
   in the intended OpenAI organization. Do not create a billable project or
   change residency settings without owner approval.
2. Prepare a dedicated Très Fort member containing only the synthetic plan
   described in [review cases](review-cases.md). Keep it outside real groups and
   disconnected from Apple Health and Intervals.icu. The constrained Apple App
   Review account intentionally cannot connect AI apps and is not suitable.
3. The owner sets the review account's personal connect code in the app and
   supplies it directly to the portal's protected review-credentials field.
   Never commit, print or transfer that code through agent tools. Reviewers can
   use the web consent form without an iPhone or Apple-account credentials.
4. Release migration `0052`, website association/fallback, updated iOS build and
   Worker under the release gate in the connection guide. Verify their exact
   release revisions and run the real-device round trip before scanning tools.
5. Host the exact domain challenge issued by the portal on the MCP host at
   `/.well-known/openai-apps-challenge`, through an owner-approved release.
   The challenge has not been requested or fabricated in this package.
6. Scan Tools. Compare the actual server catalog, annotations and responses to
   this worksheet and the review cases. Remove unnecessary personal/internal
   fields from any response identified by the scan before submitting.
7. Owner approves the concrete listing, terms and attestations; worldwide provider-supported availability is already selected.
   Submit the approved draft; retain the submission ID and review result.
8. After provider approval, publish with owner authority and retain the actual
   listing/install URL. Wire that URL into the iOS Connect action, then verify
   **install → approve → coach read/write → app sync → disconnect** on iPhone.

Preparing or merging these files grants no production, provider submission,
publication, credential or spend authority. A local or synthetic test cannot
prove directory availability or a successful real-provider callback.

## Sources checked 2026-09-12

- [OpenAI submission flow](https://developers.openai.com/plugins/deploy/submission)
- [Remote MCP review requirements](https://developers.openai.com/plugins/deploy/app-review)
- [OAuth requirements](https://developers.openai.com/plugins/build/auth)
- [Apple universal-link behavior](https://developer.apple.com/documentation/technotes/tn3155-debugging-universal-links)
