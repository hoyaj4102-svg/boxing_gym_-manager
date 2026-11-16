import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const SHARE_HOST = 'https://remember-gym.vercel.app';
const OG_IMAGE = `${SHARE_HOST}/share/og-en.png`;
const OG_URL = `${SHARE_HOST}/share`;
const DESCRIPTION = 'The simplest membership app focused on renewals. Track members, renewals, attendance, and missed visits on one screen.';
const TITLE = 're;member — Simplest membership app for renewals';
const APP_ENTRY = '/?lang=en&utm_source=x';

const shareHtml = readFileSync('share/index.html', 'utf8');
const mainHtml = readFileSync('index.html', 'utf8');

function metaContent(html, attribute, key) {
  const pattern = new RegExp(`<meta\\s+[^>]*${attribute}=["']${key}["'][^>]*>`, 'i');
  const tag = html.match(pattern);
  assert.ok(tag, `missing <meta ${attribute}="${key}">`);
  const content = tag[0].match(/\bcontent=["']([^"']*)["']/i);
  assert.ok(content, `missing content on ${attribute}="${key}"`);
  return content[1];
}

function loadWorkerPolicy() {
  const self = {
    location: { origin: 'https://boxing-gym-manager.vercel.app' },
    addEventListener() {},
    skipWaiting() {},
    clients: {
      claim() {
        return Promise.resolve();
      },
      matchAll() {
        return Promise.resolve([]);
      },
    },
  };
  const context = vm.createContext({
    self,
    caches: {},
    fetch() {
      throw new Error('fetch must not run while loading sw.js');
    },
    URL,
    setTimeout,
    clearTimeout,
    Promise,
    Map,
    Set,
    console,
  });
  vm.runInContext(readFileSync('sw.js', 'utf8'), context, { filename: 'sw.js' });
  return self.__rememberSw;
}

test('the English share page exposes X card tags', () => {
  assert.match(shareHtml, /<html lang="en">/);
  assert.match(shareHtml, /<title>re;member — Simplest membership app for renewals<\/title>/);
  assert.equal(metaContent(shareHtml, 'name', 'description'), DESCRIPTION);
  assert.equal(metaContent(shareHtml, 'property', 'og:title'), TITLE);
  assert.equal(metaContent(shareHtml, 'property', 'og:description'), DESCRIPTION);
  assert.equal(metaContent(shareHtml, 'property', 'og:image'), OG_IMAGE);
  assert.equal(metaContent(shareHtml, 'property', 'og:url'), OG_URL);
  assert.equal(metaContent(shareHtml, 'property', 'og:type'), 'website');
  assert.equal(metaContent(shareHtml, 'property', 'og:locale'), 'en_US');
  assert.equal(metaContent(shareHtml, 'name', 'twitter:card'), 'summary_large_image');
  assert.equal(metaContent(shareHtml, 'name', 'twitter:title'), TITLE);
  assert.equal(metaContent(shareHtml, 'name', 'twitter:description'), DESCRIPTION);
  assert.equal(metaContent(shareHtml, 'name', 'twitter:image'), OG_IMAGE);
  assert.equal(shareHtml.includes('http-equiv="refresh"'), false);
  assert.equal(shareHtml.includes('serviceWorker'), false);
  assert.equal(shareHtml.includes('/sw.js'), false);
});

test('the share page links into the app in English from X', () => {
  assert.match(shareHtml, /href="\/\?lang=en&amp;utm_source=x"/);
  assert.match(shareHtml, /Open re;member in English/);
  assert.match(
    shareHtml,
    /window\.setTimeout\(function \(\) \{\s*window\.location\.assign\('\/\?lang=en&utm_source=x'\);\s*\}, 6000\);/,
  );
});

test('the Open Graph image is a 1200 by 630 PNG on the share path', () => {
  const image = readFileSync('share/og-en.png');
  assert.equal(image.subarray(0, 8).toString('hex'), '89504e470d0a1a0a');
  assert.equal(image.readUInt32BE(16), 1200);
  assert.equal(image.readUInt32BE(20), 630);
  assert.ok(image.length < 2_000_000);
});

test('the main page keeps its Korean preview tags', () => {
  assert.match(mainHtml, /<html lang="ko">/);
  assert.match(mainHtml, /<title>re;member — 재등록 관리에 특화된 가장 간단한 회비관리앱<\/title>/);
  assert.equal(metaContent(mainHtml, 'property', 'og:title'), 're;member');
  assert.equal(
    metaContent(mainHtml, 'property', 'og:description'),
    '재등록 관리에 특화된 가장 간단한 회비관리앱',
  );
  assert.equal(metaContent(mainHtml, 'property', 'og:type'), 'website');
  assert.equal(mainHtml.includes('og:locale'), false);
  assert.equal(mainHtml.includes('og:image'), false);
  assert.equal(mainHtml.includes('twitter:card'), false);
  assert.equal(mainHtml.includes('remember-gym.vercel.app'), false);
  assert.equal(mainHtml.includes('utm_source'), false);
});

test('the service worker does not precache or intercept the share page', () => {
  const policy = loadWorkerPolicy();
  const origin = 'https://boxing-gym-manager.vercel.app';
  for (const shellPath of policy.APP_SHELL) {
    assert.equal(shellPath === '/share' || shellPath.startsWith('/share/'), false, shellPath);
  }
  assert.equal(policy.fetchStrategy(new Request(`${origin}/share`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/share/`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/share/index.html`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/share/og-en.png`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/share?lang=en&utm_source=x`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/index.html`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/shared`)), 'stale-while-revalidate');
});

test('vercel serves the share page in place and does not redirect it to the app', () => {
  const vercel = JSON.parse(readFileSync('vercel.json', 'utf8'));
  assert.equal(vercel.redirects, undefined);
  const share = vercel.rewrites.find((rule) => rule.source === '/share');
  assert.ok(share, 'missing /share rewrite');
  assert.equal(share.destination, '/share/index.html');
  for (const source of ['/signup', '/login', '/reset-password']) {
    const rule = vercel.rewrites.find((entry) => entry.source === source);
    assert.equal(rule.destination, '/index.html');
  }
  for (const rule of vercel.rewrites) {
    if (rule.source === '/share' || rule.source.startsWith('/share/')) {
      assert.equal(rule.destination.startsWith('/share/'), true, rule.source);
    }
  }
  for (const source of ['/share', '/share/', '/share/index.html']) {
    const rule = vercel.headers.find((entry) => entry.source === source);
    assert.ok(rule, `missing cache header for ${source}`);
    const cacheControl = rule.headers.find((header) => header.key.toLowerCase() === 'cache-control');
    assert.match(cacheControl.value.toLowerCase(), /\bno-cache\b/);
  }
});
