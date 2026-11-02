# Tres Fort on the web

The web app at `app.tresfort.app` ([plan](../docs/plans/web-app/plan.md)): a
React single-page app in `src/`, served by the `tres-fort-web` Worker, whose
same-origin gateway (`worker/gateway.ts`) finishes Sign in with Apple, keeps
the app JWT in an `HttpOnly` cookie and forwards `/api/*` to the API Worker.
Reads pass for any API path except the iPad Station link key; writes pass only
for the plan edits listed in `WRITE_ROUTES`.

## Checks

```bash
npm ci
npm run check        # typecheck, tests and build
```

The repository's `npm test` runs the same check once.

## Running it locally

Run the API Worker and this Worker side by side; the service binding finds the
API through Wrangler's local registry.

```bash
# Repository root, with APP_JWT_SECRET and DEV_AUTH_SECRET in .dev.vars
npx wrangler d1 migrations apply tres-fort-db --local
npx wrangler dev --port 8787

# web/, with DEV_AUTH_SECRET (the same value) and
# WEB_ORIGIN=http://localhost:8788 in web/.dev.vars
npm run build
npx wrangler dev --config wrangler.jsonc --port 8788 --local-upstream localhost:8788
```

`--local-upstream` keeps the request's own origin; without it Wrangler uses the
custom domain from `wrangler.jsonc`, and the gateway refuses the page's writes.
Sign in by posting to `/auth/dev` from the page (for example
`fetch('/auth/dev', { method: 'POST' })` in the browser console), which is
only routed when `DEV_AUTH_SECRET` is set. Rebuild after changing `src/`.

## Deploying

Deploying `tres-fort-web`, and the API Worker it depends on, needs the owner's
written go-ahead each time. Deploy the API Worker first when both change.
