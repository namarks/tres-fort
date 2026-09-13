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

Use the desktop app's form; terminal commands are optional:

1. Open **Settings → Plugins → Add → Add MCP server**. Older versions use
   **Settings → MCP servers → Add server**.
2. Choose **Streamable HTTP**, name the server `tres-fort`, and enter the URL
   shown by Très Fort.
3. Save, then choose **Authenticate**. Restart the server if prompted, and
   complete the browser consent using the personal connect code.

Desktop configuration does not install a hosted plugin into ChatGPT web or
iPhone. This path still requires entering a server URL once.

For users who prefer the CLI, **Advanced: command-line setup** contains:

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
and the login command. Native HTTP loopback callbacks may vary their listener
port at authorization time under [RFC 8252 section 7.3](https://www.rfc-editor.org/rfc/rfc8252#section-7.3).
Très Fort allows this for literal `127.0.0.1` and `[::1]` callbacks while keeping
the registered host, path and query fixed. Token exchange remains bound to the
exact authorized callback, including its chosen port.
These are the capabilities this setup uses; advertising
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

### A full button-based connection

The intended consumer flow is **Connect → install/authorize → return to Très
Fort**. A button cannot register an arbitrary server in another app unless that
app supports an install link or already lists the integration.

For ChatGPT/Codex, the supported distribution route is a published remote
MCP-backed plugin in their [shared directory](https://learn.chatgpt.com/docs/plugins).
Supported hosted plugins can be used on mobile; a local desktop MCP connection
is a separate surface. Prepare a [plugin submission](https://developers.openai.com/plugins/deploy/submission)
using the existing server, complete provider review, then use the issued listing
or install URL. Do not invent a plugin ID or claim that a settings/help link
completes a connection. Account authorization must still be explicit.

This remains external coaching under the user's account and does not require
Très Fort to execute or bundle model API calls. A fully mobile flow also needs
the account-authorization journey verified on iPhone; removing the connect-code
copy step is separate from removing terminal commands.

### Current verification

`test/coach_clients.test.ts` exercises synthetic Codex-shaped loopback, Claude
HTTPS, and generic loopback clients through DCR, consent, PKCE, initialization,
brief reads, shared plan updates, stale-version conflict, refresh and account
revocation. It also checks isolation, neutral attribution, compatibility aliases,
and escaped consent text. OAuth tests also cover variable native loopback ports,
rejection of other callback changes, replay and expiry.
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


For local browser regression verification, apply migrations to a disposable
local D1, start `wrangler dev --local --port 8787 --var
OWNER_AUTH_PASSPHRASE:synthetic-browser-consent`, then run
`npm run test:oauth-browser`. This uses only literal loopback addresses and
synthetic credentials. It checks IPv4 and IPv6 initial consent, retries and
PKCE exchange in Chrome with JavaScript disabled. Set `CHROME_BIN` if Chrome
is outside the default macOS application path. IPv6 callbacks use an automatic
navigation page because [CSP source lists](https://www.w3.org/TR/CSP3/#framework-directive-source-list)
cannot express IPv6 literals.

## Mobile approval and public plugin release

The iPhone implementation uses an explicit account approval screen. The OAuth
page links from the Worker to the website's narrowly associated
`/coach/authorize?request=<opaque-id>` path. Opening the link alone grants no
access. Signed-out users finish sign-in/onboarding before reviewing it. The
request expires in ten minutes. A successful approval starts a fresh ten-minute
code-exchange window. Allow/Deny are exclusive; expired or used
requests cannot issue another code. The app returns the one-time PKCE-bound
code to the registered HTTPS callback. No model key or subscription credential
is requested by Très Fort.

The public distribution package, listing draft and review cases are in
[`plugins/tres-fort`](../plugins/tres-fort/README.md). They have not been
submitted or published. A valid local manifest is not a mobile installation,
and the app does not invent a Connect URL while awaiting a provider-issued one.

Release order under explicit owner authority:

1. Apply migration `0052` before any Worker code that accesses its new table.
2. Deploy the website AASA, fallback page and no-referrer/no-store headers;
   verify the exact public assets, including JSON Content-Type on the AASA.
3. Distribute an iOS build with `applinks:tresfort.app` and the approval screen.
4. Release the matching Worker. Verify discovery, consent and data isolation;
   verify no-store on authenticated previews/decisions. Older apps retain the
   connect-code fallback.
5. Test from the real provider on a physical iPhone: verified link opens Très
   Fort, Allow returns to the initiating AI connection, a coaching read and
   reversible edit sync correctly, and disconnect invalidates access. Simulator
   navigation injection does not prove the Apple association cache or provider
   callback; do not claim an end-to-end mobile connection until this passes.
6. Complete provider scan/review/publication, then use its actual install URL
   for the consumer Connect button and repeat the full installation journey.

A failed mobile callback requires a new connection; the app never automatically
repeats an uncertain approval. Domain verification, approved terms, availability,
review-account access and publication are owner/provider inputs recorded in the
[submission worksheet](../plugins/tres-fort/submission.md).
