import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFile, stat } from 'node:fs/promises';
import { PRIVACY_HTML } from '../privacy.mjs';

const root = new URL('../', import.meta.url);
execFileSync(process.execPath, ['build.mjs'], { cwd: root });
const pages = new Map([
  ['/', await readFile(new URL('dist/index.html', root), 'utf8')],
  ['/privacy', await readFile(new URL('dist/privacy/index.html', root), 'utf8')],
]);

test('the standalone policy uses the same content as the app policy', () => {
  assert.equal(pages.get('/privacy'), PRIVACY_HTML);
});

test('every local navigation target, image, and font exists in the public build', async () => {
  for (const [pathname, html] of pages) {
    for (const match of html.matchAll(/(?:href|src)="([^"]+)"|url\('([^']+)'\)/g)) {
      const target = match[1] ?? match[2];
      if (target.startsWith('mailto:') || target.startsWith('https://')) continue;
      const url = new URL(target, `https://tresfort.app${pathname}`);
      if (pages.has(url.pathname)) {
        if (url.hash) assert.ok(pages.get(url.pathname).includes(`id="${url.hash.slice(1)}"`), `${pathname}: missing ${target}`);
      } else {
        assert.ok((await stat(new URL(`dist${url.pathname}`, root))).isFile(), `${pathname}: missing ${target}`);
      }
    }
    for (const image of html.matchAll(/<img\b[^>]*>/g)) {
      assert.match(image[0], /\balt="[^"]*"/);
      assert.match(image[0], /\bwidth="\d+"/);
      assert.match(image[0], /\bheight="\d+"/);
    }
    assert.doesNotMatch(html, /<script\b|<iframe\b|<form\b/i);
  }
});

test('mobile approval uses a narrowly claimed, verified app link with a non-authorizing fallback', async () => {
  const aasa = JSON.parse(await readFile(new URL('dist/.well-known/apple-app-site-association', root), 'utf8'));
  assert.deepEqual(aasa.applinks.details[0].appIDs, ['8BA2RY6RCA.com.nmarkspdx.tresfort']);
  assert.deepEqual(aasa.applinks.details[0].components.map(component => component['/']), ['/coach/authorize']);
  const fallback = await readFile(new URL('dist/coach/authorize/index.html', root), 'utf8');
  assert.match(fallback, /No access has been granted/);
  assert.doesNotMatch(fallback, /<script|access_token|refresh_token|passphrase/);
  const headers = await readFile(new URL('dist/_headers', root), 'utf8');
  assert.match(headers, /Referrer-Policy: no-referrer/);
});
