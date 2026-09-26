# Release 1.0 (42)

## Source and authority

The owner requested the latest production and TestFlight release on 2026-09-14
Pacific. The released source is `5df9208fc01219f298866ee4528cda533b86d33d`, tree
`f4471977856150fd614ca6b9da681753208887f8`, from
[PR #207](https://github.com/namarks/tres-fort/pull/207). Its tree matches the
independently reviewed PR head `6c131b9b10c7feefac61cb8836627f8b68095b5a`.
All eight checks passed on both the PR and
[the merged-source run](https://github.com/namarks/tres-fort/actions/runs/34921837927).
This release includes the simpler Claude/Codex setup and the other changes merged
since build 41. It does not submit or publish the prepared OpenAI plugin.

## Production

At `2026-09-15T02:56:59.495194Z`, Cloudflare deployment
`5d5cc071-3ddc-4b58-83ac-82e1e61c45bc` activated Worker version
`92adb0e0-28bd-4952-81ad-b09029f75ac9` at **100% traffic**. Its source/tree
annotation matches the release above. The preceding version was
`362ecaff-f79b-4409-b144-e55b04a207d5` (build 41).

No migration was needed: the production ledger already includes migration 0052,
Wrangler reported no pending migrations, and the foreign-key check returned no
violations. No database changes were made. The existing D1/R2 bindings, runtime
settings, secret bindings and hourly cron were preserved.

Public checks at `2026-09-15T02:58:11.411Z` passed: health and both OAuth metadata
endpoints returned HTTP 200; unauthenticated MCP POST and API state returned 401;
MCP advertised protected-resource discovery. Health does not expose a source SHA;
the Cloudflare deployment receipt separately establishes the serving source.

The live website was already current. Its deployed source `3f4c9274` and this
release have the identical website tree `c8e93ba7c0ee7325d9ffa11911694b859a6141ee`.
The public AASA JSON exactly matches the release's narrow `/coach/authorize`
association. The fallback page matches its expected content and returns
`Cache-Control: no-store` and `Referrer-Policy: no-referrer`. No website
redeployment or terms publication was needed.

## iOS

The exact source above archived and exported successfully as **1.0 (42)**.
Distribution signatures verify for both app and widget; both report build 42,
and neither permits debugging. The app retains `applinks:tresfort.app` and the
Worker-domain association. Apple validation reported `VERIFY SUCCEEDED with no
errors`. Upload at `2026-09-15T02:59:07Z` reported `UPLOAD SUCCEEDED with no errors`,
delivery UUID `45f5837a-cd7a-40a0-84c9-20b1155faa33`.

Exported IPA SHA-256:
`9599e6da3e861053b109e21b0609c5ed2cb4b25cbb720db3738193cb6639eeb1`.

At `2026-09-15T03:02:09.514Z`, Apple reported build
`45f5837a-cd7a-40a0-84c9-20b1155faa33` **VALID** and **IN_BETA_TESTING**.
A complete group-build read confirmed assignment to internal **Testers**
(`5df996bf-8c8b-471e-b79e-f626a4f98211`). The external Alpha Testers group does
not have build 42; its external state is `READY_FOR_BETA_SUBMISSION`.
No external-beta submission or tester-group change was made.

## App Store and device boundaries

A fresh Apple read at `2026-09-15T03:02:09.514Z` still shows version 1.0,
**build 40**, `WAITING_FOR_REVIEW`, with release type **AFTER_APPROVAL**.
This differs from the older manual-release receipt. This run did not change the
submission, selected build or release setting and did not publicly release an
App Store build. Uploading build 42 to TestFlight does not replace build 40 in
App Review.

A real-provider iPhone connection, authenticated training read/reversible edit,
return to the provider, and disconnect/reconnect remain unverified. Public
health, synthetic tests and Apple processing do not establish those behaviors.
The canonical coaching plan retains that owner-device handoff and the separate
plugin publication gate.

Value-free release receipts, source manifest, signing verification and tool logs
are retained on the release host under the current task's `release-42` artifact
directory. Temporary build and worktree files are cleaned after verification.
