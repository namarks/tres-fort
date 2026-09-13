# Connect an external AI coach

Coaching conversations happen in the member's chosen AI app. Très Fort stores
training data and exposes the same account-scoped tools to every client. The
member supplies their AI account or subscription. Très Fort includes no model
API usage, API-key entry, embedded chat, or automatic model selection.

## Setup

In Très Fort, open **Profile → Coach → Set up your AI coach** (or **Connect
another AI app**). Choose an app, review the disclosure, and generate a connect
code. Copy the server URL from that environment's setup screen. The personal
code is entered only on the Très Fort OAuth consent page, never into chat,
a shell command, an API-key field, or a bearer-token field.

### Codex

On a computer with Codex CLI installed, add the URL shown by Très Fort:

```sh
codex mcp add tres-fort --url "https://<your-worker>.workers.dev/mcp"
codex mcp login tres-fort
```

Complete the browser consent using the personal connect code. In Codex, ask
“Use Très Fort to load my coaching brief.” Confirm the returned plan belongs
to the signed-in Très Fort member. The CLI and other Codex clients using the
same host configuration share the connection; a different host needs its own
setup. Provider account access and limits are controlled by that provider.

[Official Codex MCP documentation](https://developers.openai.com/codex/mcp)
documents Streamable HTTP, OAuth, Dynamic Client Registration, server instructions,
and the login command. These are the capabilities this setup uses; advertising
support is not evidence of a successful connection to a deployed Très Fort release.

### Claude

Use an account supporting custom connectors. Open **Settings → Connectors → Add
custom connector**, name it Très Fort, and enter the server URL. Leave optional
client ID/secret fields empty so Dynamic Client Registration can run. Connect,
then enter the personal code on the Très Fort consent page. Existing Claude
OAuth grants continue working; switching the app's setup choice does not revoke them.

### Other compatible apps and models

The host app must support remote MCP over Streamable HTTP, OAuth discovery,
Dynamic Client Registration, authorization code with PKCE S256, and refresh.
Apps requiring only a provider API key or static token are not covered by this
member setup. GLM and Muse are model families, not proof of host compatibility.
Choose a host that supports the connection and configure the model there.

Z.AI documents [GLM in OpenCode](https://docs.z.ai/devpack/tool/opencode), and Meta
has documented [Muse tool/MCP use and OpenCode examples](https://ai.meta.com/blog/introducing-muse-spark-meta-model-api/).
These are candidate host/model routes, not end-to-end Très Fort certifications.
No provider API credentials are stored or forwarded by Très Fort.

## Shared behavior and compatibility

- `get_coach_brief` returns the same current context as `coach://state/current`,
  plus the same coaching instructions returned at initialization. `coach_brief`
  remains available as an MCP prompt. Clients need not support resources or
  prompts to read the brief.
- The iOS app is the primary set logger. Narrating a workout does not authorize
  duplicate logging. Tools keep existing ownership, version checks, audit trails,
  and soft deletion behavior. A stale plan version requires a fresh read.
- New MCP notes use `author='coach'`. Historic `author='claude'` rows remain as
  recorded. No model identity is inferred from a self-reported OAuth client name.
- `GET /api/me` supplies `coach` and the identical legacy `claude` alias. The new
  iOS app prefers `coach` and falls back to `claude` for an older Worker. An old
  iOS build still uses its old labels; use the updated build for neutral copy.
- Profile reports aggregate OAuth access and the most recent MCP write, not
  individual model health. **Disconnect all AI apps** revokes that account's
  grants, including old Claude grants, without deleting training data or another
  member's access. Rotating a connect code alone does not revoke existing grants.
- Consent identifies the self-reported app name as such and explains access by
  the app and its configured model provider. Retrieved data remains subject to
  those providers' policies after disconnect. Apple Health group sharing is
  separate from the member's own authorized coach access.

## Verification and release

`test/coach_clients.test.ts` exercises synthetic Codex-shaped loopback, Claude
HTTPS, and generic loopback clients through DCR, consent, PKCE, initialization,
brief reads, shared plan updates, stale-version conflict, refresh and account
revocation. It also checks isolation, neutral attribution, compatibility aliases,
and escaped consent text. Existing OAuth integrity tests cover replay and expiry.
These protocol tests do not invoke a model or connect a real provider account.

For a released Worker and iOS build, the owner should complete Codex browser
sign-in with their own code, load their plan, explicitly request one reversible
plan change, confirm it in iOS, then test disconnect and reconnect. Never route
owner-managed secrets through an agent or use the operator static bearer for
member onboarding. Canonical release/verification state lives in the
[workstream plan](plans/bring-your-own-ai-coach/plan.md).

The free offering uses users' own supported AI subscriptions. A future paid
package may bundle in-app coaching and API calls when cost and product economics
justify it; its pricing, usage limits, billing and provider decisions remain future work.
