# November security remediation release boundary

This change addresses SEC-01 through SEC-04 in [the audit](security-2026-11.md).
Repository verification uses synthetic credentials and local D1. No production
migration, secret provisioning, backfill, deployment, or iOS distribution is
authorized or performed by opening the remediation PR.

## Delivered behavior

- Intervals callbacks save an encrypted, ten-minute pending exchange. A new
  completion secret is delivered only to the returning app. `/auth/intervals/finish`
  requires that secret, the original member and app session, and the unchanged
  credential generation. Activation, single-use consumption, and audit commit
  together; only then can activity import start. Old callback states fail closed.
- Coach fallback codes are generated server-side with 256 random bits, expire
  in ten minutes, and authorize once. The API accepts `{}` and returns the code
  once; only its hash is stored. Reusable member/owner passwords no longer
  authorize consent. D1 limits consent submissions to ten per minute per
  Cloudflare-provided client IP, across isolates and registered OAuth clients.
  Existing authenticated mobile approval and existing coach grants keep working.
- New app JWTs carry a stable session-family ID. Renewal preserves it; logout
  revokes the family in D1. Legacy tokens and renewals derive the same ID from
  signed member, authentication time, and client claims. Independent new sessions
  stay active. Legacy sign-ins with identical claims are indistinguishable and
  revoke together. Web/iOS user-facing sign-out waits for server acknowledgement;
  failures retain the session and show a retryable error.
- New coach access/refresh credentials are stored as SHA-256 digests, never
  accepted as bearers themselves. Intervals API keys, access tokens, refresh
  tokens, and pending exchanges use AES-256-GCM with random nonces and
  member/purpose-bound additional data. The encryption key lives outside D1.

## Authorized release procedure

1. Obtain separate authority for production schema, secret, deploy, and client
   distribution actions. Confirm the exact release revision passed the repository
   CI/review gates and the release checks required for iOS distribution.
2. Apply migration `0065_security_credentials.sql` through the repository's
   guarded migration procedure. This adds schema with credential enforcement
   initially off; it does not erase or convert existing connections.
3. Generate and retain a dedicated 32-byte random key, base64 encoded, in the
   operator's secret manager. Provision `CREDENTIAL_ENCRYPTION_KEY` as a Worker
   secret using `wrangler secret put`, never in vars, SQL, source, or logs. This
   must be the same key used by the backfill. Losing or replacing it makes stored
   provider credentials unreadable; key rotation requires an explicit re-encryption
   operation and is not accomplished by replacing this secret alone.
4. Deploy the updated API Worker, web gateway, and native client as one coordinated
   release. Old native clients cannot finish new Intervals links or generate the
   new coach fallback codes, and old sign-out UI does not invoke revocation.
   Existing logged-in sessions and already-linked accounts remain readable by
   the updated Worker during the transition. Do not keep old API Workers serving
   traffic once the new Worker starts storing ciphertext or token hashes.
5. Run the credential backfill from an approved operator environment with Node
   22.18+ and these environment variables supplied by the secret manager:
   `CLOUDFLARE_ACCOUNT_ID`, `CLOUDFLARE_D1_DATABASE_ID`, a scoped
   `CLOUDFLARE_API_TOKEN` with D1 write permission, and the same
   `CREDENTIAL_ENCRYPTION_KEY`. Do not print their values or pass them as command
   arguments. Run `node scripts/backfill-security-credentials.mjs --apply`.
   The script uses the [D1 parameterized query API](https://developers.cloudflare.com/api/resources/d1/subresources/database/methods/query/).
6. Require a successful value-free receipt with `enforced:true`. The script
   authenticates existing ciphertext before writing, converts plaintext rows
   with compare-and-swap conditions, increments provider generations to fence
   in-flight sync, and preserves athlete IDs, cached workouts, and OAuth grant
   lifetimes. Unchanged encrypted rows are reused. A concurrent change is never
   overwritten. Enforcement is atomic and refuses any remaining plaintext;
   failed runs may have converted some rows, so inspect status before explicitly
   rerunning the idempotent procedure with the same key.
7. Verify `SELECT enforced FROM credential_storage_policy WHERE id=1` returns
   `1`. The guard rejects plaintext credential inserts/updates and refuses
   downgrade. Verify a real member can finish an Intervals connection, use an
   existing coach connection through refresh, and sign out such that an earlier
   bearer is rejected. Keep all credential values out of verification output.

## Recovery and remaining boundaries

Forward-fix with encryption/hash-aware code after the first protected write.
An old Worker cannot read the protected credentials and may attempt to recreate
plaintext; do not roll back to it or disable the storage guard. Keep the key
available for any restored encrypted database. Historical exports/backups still
contain their original credentials: conversion does not rewrite them. If an
actual disclosure is suspected, rotate/revoke the exposed credentials separately.

SEC-04's protection for existing rows is complete only after the backfill and
enforcement receipt. SEC-03's user-facing logout guarantee requires the updated
web gateway/native client. Local synthetic tests establish implementation behavior;
production activation and physical-device/provider acceptance remain release work.
