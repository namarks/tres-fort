# Security audit — November 2026

Audit date: 2026-11-03 (America/Los_Angeles).

Audited revision: `110e5f4e003aebb5831acc99b3843206a2a39829`.

Scope: Cloudflare API Worker and D1 services, MCP/coach authorization, web gateway and application, and iOS authentication, account isolation, integration linking, and local credential handling.

**Result: one High and three Medium findings.** Each includes its prerequisites; this is not a claim that production credentials have been stolen or that every deployment is exploitable. No application code was changed during the audit. The subsequent remediation is recorded below.

| ID | Severity | Finding | Required attacker capability |
| --- | --- | --- | --- |
| SEC-01 | High | Forwarded Intervals OAuth authorization URLs connect the victim's provider account to the attacker's Tres Fort account | Own Tres Fort account; induce victim to approve a legitimate provider consent page |
| SEC-02 | Medium | Public coach authorization permits repeated guesses against weak member passphrases | Victim has configured a guessable passphrase; endpoint is not protected by an independently configured effective rate limit |
| SEC-03 | Medium | Signing out does not revoke the app/web session credential | Previously copied, still-valid app JWT or web session-cookie value |
| SEC-04 | Medium | D1 stores reusable coach and provider credentials in cleartext | Read access to live credential rows or a sufficiently recent database export |

## SEC-01 — High: Intervals account linking is not bound to the returning user agent

**Locations:** [src/routes/intervalsAuth.ts:55](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/routes/intervalsAuth.ts#L55) (authenticated start), [src/routes/intervalsAuth.ts:91](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/routes/intervalsAuth.ts#L91) (callback selects the target member solely from state), [src/routes/intervalsAuth.ts:151](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/routes/intervalsAuth.ts#L151) (credentials committed and import started), [src/db.ts:1970](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L1970) (state stores member/generation but no browser binding), and [ios/TresFort/Intervals/IntervalsOAuth.swift:33](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/ios/TresFort/Intervals/IntervalsOAuth.swift#L33) (app receives a success indicator, not an authenticated completion transaction).

**Issue and impact.** The random, expiring, single-use `state` identifies who started the flow, but does not establish that the person returning from Intervals is that member. `POST /auth/intervals/start` returns a transferable provider authorization URL. The public callback exchanges the code and immediately saves the resulting credentials to the initiating member, then starts importing that provider's activities. There is no browser-session check or authenticated app finalization before the connection becomes usable.

**Concrete exploit path:**

1. Attacker A signs into their own Tres Fort account and calls `POST /auth/intervals/start`.
2. A sends the returned, unmodified `authorize_url` to victim B as a connection link. B opens the genuine Intervals page, signs into B's Intervals account if necessary, and approves Tres Fort.
3. Intervals redirects B's browser to `/auth/intervals/callback?code=<B-code>&state=<A-state>`. The callback needs no Tres Fort cookie or bearer and writes B's provider token under A's `user_id`.
4. A reads B's imported activity history through A's own `GET /api/state` or coach connection. A can also invoke the supported Intervals write operations using the now-linked provider credential. The callback's eventual app redirect does not undo the already-committed connection.

This requires victim interaction and provider consent; it does not require guessing another member's UUID, intercepting TLS, or learning B's Tres Fort token.

**Validation.** A temporary real-D1 probe created A and B, used A's authenticated start URL, mocked the provider exchange as B's athlete, and invoked the callback with no app authentication. It observed HTTP 302 success, B's provider credential stored under A, and B's synthetic private activity returned by A's authenticated state pull. B's Tres Fort connection remained unset. This validates the application's binding failure; the live provider consent UI was not exercised.

**Minimal fix.** Defer credential activation/import until the returning app proves that it is the intended member. Have the callback create a short-lived pending exchange and return a fresh, single-use completion secret only to the receiving app; require an authenticated finish request whose member matches the original attempt and which presents that secret. Do not expose that secret to the initiating account through polling or derive it from the transferable `state`. A proper initiating-browser session binding is an alternative. Retain state expiry, atomic consumption, and the credential-generation check. Adding only a user ID to state or checking the success deep link after committing does not fix this flow.

OAuth's state defense must bind the transaction to the user agent, beyond being random and single-use. See [RFC 9700 §4.7.1](https://www.rfc-editor.org/rfc/rfc9700.html#section-4.7.1).

**Regression acceptance:** forwarding A's provider URL to B must not activate credentials or import activities for A; the original member/app must complete an authenticated, transaction-bound finish.

## SEC-02 — Medium: Weak coach passphrases can be guessed through the public authorization endpoint

**Locations:** [src/routes/api.ts:2062](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/routes/api.ts#L2062) (member sets arbitrary passphrase; only eight-character minimum), [src/oauth.ts:348](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/oauth.ts#L348) (public authorization POST), [src/oauth.ts:382](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/oauth.ts#L382) (passphrase alone selects the member), and [src/db.ts:1396](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L1396) (each guess is checked against every configured member).

**Issue and impact.** The server accepts values such as `password1` as the sole credential for obtaining full coach access. Anyone can register an OAuth client, choose its callback and PKCE verifier, and repeatedly submit candidate passphrases. The repository has no attempt budget, delay, or rate-limit enforcement on this path. Because the lookup checks all member hashes, an attacker does not need a victim's username or account ID. PBKDF2 protects stored passphrases but does not prevent online guessing.

**Concrete exploit path:**

1. A member configures a weak passphrase using the supported `POST /api/me/mcp-passphrase` API.
2. An unauthenticated attacker registers a client through `POST /oauth/register` with a callback they control.
3. The attacker sends dictionary guesses to `POST /oauth/authorize`, supplying their registered client, callback, and S256 challenge. Wrong guesses return 401; a matching guess returns a code bound to the victim.
4. The attacker redeems the code with their own PKCE verifier. The resulting bearer permits victim-scoped coach reads and mutations, including training plans and workout records.

**Validation.** A synthetic victim successfully configured `password1`. Twenty consecutive incorrect authorization attempts returned 401 without a lockout; the next matching attempt returned 302, exchanged for tokens, resolved to the victim's user ID, and successfully called `get_current_plan` through MCP.

**Qualification.** The current iOS UI generates a substantially stronger random code at [ios/TresFort/GroupModel.swift:1197](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/ios/TresFort/GroupModel.swift#L1197). This finding does not claim those generated codes are practically guessable. It concerns the weaker server-accepted credential path and any weak existing values. Production WAF/rate-limit configuration and the strength of real member passphrases were not inspected.

**Minimal fix.** Stop accepting arbitrary user-selected passwords as coach connect codes: issue cryptographically random, short-lived, single-use codes server-side and reject or retire legacy weak credentials. Enforce a shared attempt budget on public authorization before expensive verification, including controls that cannot be reset merely by registering another OAuth client. Preserve the existing authenticated in-app approval flow. If legacy passwords must remain temporarily, enforce server-side online-guessing limits on that path immediately.

**Regression acceptance:** the API cannot provision `password1` as a coach credential; repeated failed public authorizations hit an enforced limit; successful code use consumes the code.

## SEC-03 — Medium: App and web logout leave copied session tokens usable

**Locations:** [web/worker/gateway.ts:197](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/web/worker/gateway.ts#L197) (sign-out only expires the local cookie), [ios/TresFort/AuthModel.swift:716](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/ios/TresFort/AuthModel.swift#L716) (sign-out only clears local state/Keychain), [src/auth.ts:147](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/auth.ts#L147) (live account/deletion check but no session revocation), [src/auth.ts:15](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/auth.ts#L15) (60-day bearer and 180-day absolute session limits), and [src/routes/auth.ts:413](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/routes/auth.ts#L413) (renewal accepts the same still-valid bearer).

**Issue and impact.** Logout removes a credential from the current device, but never invalidates it on the server. A copied credential remains a valid way to read private state, including the member's GPS routes, and make ordinary account/plan/workout mutations after the member signs out. It can also be renewed within the original 180-day session limit. Account deletion does invalidate access; ordinary logout does not.

**Concrete exploit path:**

1. An attacker obtains a valid app JWT or the value of `__Host-tf_session` before logout, for example through prior access to a browser profile or a compromised device.
2. The legitimate member signs out. The web gateway returns 204 and clears its cookie, or iOS clears its stored token.
3. The attacker continues sending `Authorization: Bearer <copied-token>` directly to the API, and calls `POST /auth/renew` before expiry to retain access within the session's absolute lifetime.

No token-extraction vulnerability is asserted here. The defect is the inability to terminate an already-copied session credential by signing out.

**Validation.** A temporary probe called the actual web gateway's sign-out handler with a valid synthetic web JWT. It observed HTTP 204 and `Max-Age=0`, with no API revocation call. The same JWT then received 200 from `GET /api/me` and `POST /auth/renew`; the renewed JWT also received 200. The native sign-out equivalent was verified by source inspection, not a physical-device run.

**Minimal fix.** Give app/web JWTs a server-tracked session ID and reject revoked sessions in both `requireAppJwt` and renewal. Add an authenticated API endpoint to revoke that session and invoke it from web and iOS sign-out. Keep local cleanup, but distinguish local/offline sign-out from acknowledged server revocation. A user session-version field can be a smaller alternative if intentionally revoking all of that member's app sessions is acceptable. Shortening JWT expiry alone would only reduce the exposure window.

**Regression acceptance:** after acknowledged logout, the copied original bearer and any bearer renewed from the same session before logout both fail API access and renewal.

## SEC-04 — Medium: Database reads expose directly reusable coach and Intervals credentials

**Locations:** [src/services/oauthGrants.ts:166](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/services/oauthGrants.ts#L166) and [src/services/oauthGrants.ts:191](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/services/oauthGrants.ts#L191) (raw OAuth token pair persisted), [src/oauth.ts:65](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/oauth.ts#L65) (raw access-token lookup), [src/oauth.ts:500](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/oauth.ts#L500) (raw refresh-token lookup), [src/db.ts:1802](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L1802) (raw Intervals API key), and [src/db.ts:1876](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L1876) / [src/db.ts:1920](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L1920) (raw Intervals OAuth credentials).

**Issue and impact.** D1 contains bearer-ready MCP access/refresh tokens and provider credentials. A read-only database disclosure therefore grants live API write authority as affected members, extending the impact beyond the historical data present in the database. The coach access tokens need only be verified by the server, so retaining their original values is unnecessary. Intervals credentials do need to be recovered for provider calls, but currently have no application-level encryption boundary separating database readers from token users.

**Concrete exploit path:**

1. An attacker obtains a current read-only D1 export or otherwise reads `oauth_tokens`.
2. They copy an unexpired, unrevoked `access_token` into an MCP Authorization header and act as the associated member.
3. They can also submit the row's `refresh_token` and public `client_id` to `POST /oauth/token` to obtain a successor while the grant remains eligible. No additional client secret or user interaction is required.
4. Independently, copied `users.intervals_oauth_access_token` or `intervals_api_key` values can be used against Intervals with the permissions originally granted, outside Tres Fort's endpoint restrictions.

This is a post-disclosure escalation finding. No publicly accessible database export, production secret leak, or database-read exploit was established. D1 storage encryption does not protect against an authorized SQL reader/export exposing the logical column values.

**Validation.** A temporary probe issued a real synthetic coach grant, selected its persisted token row, and verified that the selected access token authenticated as its member. The selected refresh token plus client ID returned HTTP 200 and a valid successor for the same member. Intervals plaintext storage was verified from the write bindings and the synthetic callback probe; no real provider credential was read or used.

**Minimal fix.** Persist only a SHA-256 digest (or keyed digest) of high-entropy MCP access and refresh tokens; hash the presented bearer before lookup and return raw values only when issuing them. Apply this consistently to issuance, rotation, lookup, and replay lineage, and migrate or invalidate existing plaintext rows. Encrypt recoverable provider credentials with authenticated encryption under a separately managed Worker secret, including member ID and credential type as authenticated context. Keep encryption keys out of D1 and its exports. Provider credentials cannot simply be hashed because outbound calls need their original value.

**Regression acceptance:** a D1 credential-row export contains no usable bearer or recoverable provider secret by itself; normal access, refresh rotation, replay detection, and caller-scoped revocation still work.

## Other reviewed boundaries

No additional exploitable issue was confirmed in these reviewed paths:

- **Direct member isolation:** workout/slot ownership, session/set edits and UUID collisions, active plans and snapshots, group membership checks, and caller-scoped coach revocation. For example, set edits join the owning session at [src/db.ts:5717](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L5717); route lookup constrains both the recorded activity and joined route to the caller at [src/db.ts:9453](https://github.com/namarks/tres-fort/blob/110e5f4e003aebb5831acc99b3843206a2a39829/src/db.ts#L9453). GPS routes were not exposed by the inspected group or MCP serializers.
- **D1 query construction:** reviewed request-derived values use bound parameters. Dynamic assignment columns and SQL fragments reviewed were selected from fixed implementation logic rather than inserted from arbitrary request keys. No SQL-injection exploit was found.
- **Auth and web protections:** Apple signature/issuer/audience checks; web sign-in state and nonce cookies; Secure/HttpOnly session cookies; same-origin write checks and gateway route restrictions; MCP PKCE, redirect matching, atomic code redemption, refresh-family replay handling, and account-deletion fencing.
- **iOS:** HTTPS API configuration, Keychain bearer storage, account-scoped local state and session-epoch checks, and authenticated/encrypted Station transport. Native keychain extraction, physical-device behavior, and operating-system compromise were not tested.
- **Secrets and errors:** targeted current-tree secret-pattern inspection found no obvious embedded live private key/token in the inspected application/configuration files. Error-redaction tests passed. This was not a full historical Git-secret scan or a review of deployed secrets, CI secret stores, backups, or Cloudflare account permissions.

These are bounded review results, not a guarantee that every route or possible interleaving is secure.

## Verification record

All execution used an isolated temporary copy of the audited source and synthetic local D1 data. The four audit probes disabled real provider networking and mocked Intervals responses. Temporary probe/configuration files were not added to the repository.

| Verification | Result |
| --- | --- |
| Four targeted audit probes described above | 4 passed |
| Existing API, multi-user MCP, OAuth/grant integrity, Intervals connect, recorded-route, group, Apple-auth, and retired-review-auth suites | 214 passed across 12 files |
| Existing account-deletion, invite/auth, and error-privacy suites | 34 passed across 3 files |
| Existing web gateway suite, executed with a temporary Node Vitest configuration | 19 passed |

Backend suite command, from the temporary copy:

```sh
./node_modules/.bin/vitest run test/api.test.ts test/mcp_multiuser.test.ts test/oauth.test.ts test/oauth_integrity.test.ts test/intervals_connect.test.ts test/intervals_oauth.test.ts test/run_recording.test.ts test/group_safety.test.ts test/groups.test.ts test/group_feed.test.ts test/auth_apple_provider.test.ts test/app_review_auth.test.ts
./node_modules/.bin/vitest run test/account_deletion.test.ts test/auth_invite.test.ts test/error_privacy.test.ts
```

The probes assert the observed insecure behaviors, so their passing results are evidence for the findings, not security acceptance. The existing passing tests cover other enforced boundaries and do not invalidate the findings.

Production configuration, live D1, real member data, live OAuth consent, and the iOS simulator/device test suites were not exercised. External WAF rules may mitigate SEC-02; actual deployment exposure must not be inferred solely from this source audit. Only this audit document was added to the checkout.


## Remediation follow-up

The remediation change addresses all four findings with a session-bound Intervals
finish transaction, server-issued single-use coach codes with shared rate limits,
server-side app-session revocation, and hashed/encrypted credential storage.
Regression coverage is in `test/security_credentials.test.ts`,
`test/credential_backfill.test.ts`, the existing OAuth/provider suites,
`web/test/gateway.test.ts`, and `ios/TresFortTests/AuthModelTests.swift`.

Local validation: TypeScript checks; all real-D1 backend test shards; all 91 web
tests plus web typecheck/build; the website, upload-script and query-plan checks
in `npm test`; the plan graph check; and four Chrome OAuth browser flows
(IPv4/IPv6, initial consent/retry, JavaScript disabled). Native build/tests run
in repository CI.

These are implementation results, not production activation evidence. Existing
credential rows remain subject to SEC-04 until the authorized backfill succeeds
and the storage guard is enabled. See the [release procedure](security-2026-11-release.md)
for migration, key provisioning, client compatibility, enforcement, and recovery.
