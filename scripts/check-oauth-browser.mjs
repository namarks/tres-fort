// Local-only behavioral coverage for browser-enforced OAuth navigation.
// Run a migrated local Worker with OWNER_AUTH_PASSPHRASE set to the synthetic
// value below. No real member or provider credentials are used or printed.
import assert from 'node:assert/strict';
import { createServer } from 'node:http';
import { chromium } from 'playwright-core';

const base = new URL(process.env.OAUTH_TEST_BASE ?? 'http://127.0.0.1:8787');
assert(base.protocol === 'http:' && ['127.0.0.1', '[::1]'].includes(base.hostname)
  && !base.username && !base.password && base.pathname === '/' && !base.search && !base.hash,
'OAUTH_TEST_BASE must be a literal HTTP loopback origin.');
const browser = await chromium.launch({ headless: true,
  executablePath: process.env.CHROME_BIN ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' });

try {
  for (const { host, retryConsent } of ['127.0.0.1', '::1'].flatMap(host =>
    [false, true].map(retryConsent => ({ host, retryConsent })))) {
    const literal = host === '::1' ? '[::1]' : host;
    let callbackReferrer;
    const listener = createServer((req, res) => {
      callbackReferrer = req.headers.referer;
      res.writeHead(200, { 'content-type': 'text/plain' });
      res.end('Synthetic OAuth callback received');
    });
    await new Promise((resolve, reject) => {
      listener.once('error', reject);
      listener.listen(0, host, resolve);
    });
    let context;
    try {
      context = await browser.newContext({ javaScriptEnabled: false });
      const callback = new URL(`http://${literal}:${listener.address().port}/callback`);
      const registration = await fetch(new URL('/oauth/register', base), {
        method: 'POST', headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ client_name: 'Synthetic browser check',
          redirect_uris: [`http://${literal}/callback`] }),
      });
      assert.equal(registration.status, 201);
      const { client_id } = await registration.json();
      const verifier = crypto.randomUUID() + crypto.randomUUID();
      const challenge = Buffer.from(await crypto.subtle.digest('SHA-256',
        new TextEncoder().encode(verifier))).toString('base64url');
      const state = 'synthetic&"<state>';
      const params = new URLSearchParams({ client_id, redirect_uri: callback.href,
        response_type: 'code', code_challenge: challenge, code_challenge_method: 'S256',
        state, scope: 'mcp', resource: new URL('/mcp', base).href });
      const page = await context.newPage();
      const violations = [];
      page.on('console', message => {
        if (/form-action|Content Security Policy/i.test(message.text())) violations.push(message.text());
      });
      const response = await page.goto(new URL(`/oauth/authorize?${params}`, base).href);
      assert.equal(response.status(), 200);
      const policy = response.headers()['content-security-policy'];
      assert(policy.includes(host === '::1' ? "form-action 'self';"
        : `form-action 'self' ${callback.origin};`));
      if (retryConsent) {
        // Failed-code retries must retain the same browser policy and complete.
        await page.locator('input[name=passphrase]').fill('synthetic-wrong-code');
        const retry = page.waitForResponse(res => res.url() === new URL('/oauth/authorize', base).href
          && res.request().method() === 'POST');
        await page.locator('button[type=submit]').click();
        assert.equal((await retry).status(), 401);
        await page.locator('.err').waitFor();
      }
      await page.locator('input[name=passphrase]').fill('synthetic-browser-consent');
      await Promise.all([
        page.waitForURL(url => url.origin === callback.origin && url.pathname === callback.pathname,
          { timeout: 10_000 }),
        page.locator('button[type=submit]').click(),
      ]);
      assert.deepEqual(violations, []);
      assert.equal(callbackReferrer, undefined);
      const received = new URL(page.url());
      assert.equal(received.searchParams.get('state'), state);
      assert(received.searchParams.get('code'));
      const exchange = await fetch(new URL('/oauth/token', base), {
        method: 'POST', body: new URLSearchParams({ grant_type: 'authorization_code',
          client_id, redirect_uri: callback.href, code: received.searchParams.get('code'),
          code_verifier: verifier, resource: new URL('/mcp', base).href }),
      });
      assert.equal(exchange.status, 200);
      console.log(`PASS: ${host} consent ${retryConsent ? 'retry' : 'first attempt'} -> callback -> PKCE exchange; JavaScript disabled, no CSP violation or referrer.`);
    } finally {
      try { await context?.close(); }
      finally { await new Promise(resolve => listener.close(resolve)); }
    }
  }
  console.log(`Browser: ${browser.version()}`);
} finally {
  await browser.close();
}
