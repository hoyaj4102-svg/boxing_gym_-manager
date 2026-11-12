import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const CANONICAL_ORIGIN = 'https://boxing-gym-manager.vercel.app';
const THIRD_PARTY_HOSTS = new Set([
  'fonts.googleapis.com',
  'fonts.gstatic.com',
  'cdn.jsdelivr.net',
]);

function shellFile(shellPath) {
  if (shellPath === '/') return 'index.html';
  if (!shellPath.startsWith('/') || shellPath.includes('..')) {
    throw new Error('APP_SHELL entries must be root-relative paths');
  }
  return shellPath.slice(1);
}

function expectedCacheVersion(shellPaths) {
  const hash = createHash('sha256');
  for (const shellPath of [...shellPaths].sort()) {
    hash.update(shellPath);
    hash.update('\0');
    hash.update(readFileSync(shellFile(shellPath)));
    hash.update('\0');
  }
  return `remember-${hash.digest('hex').slice(0, 16)}`;
}

function loadWorkerPolicy() {
  const listeners = {};
  const self = {
    location: { origin: CANONICAL_ORIGIN },
    addEventListener(type, fn) {
      if (!listeners[type]) listeners[type] = [];
      listeners[type].push(fn);
    },
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
  return { policy: self.__rememberSw, listeners };
}

function isAllowedAbsoluteUrl(value) {
  let url;
  try {
    url = new URL(value);
  } catch {
    return false;
  }
  if (url.origin === CANONICAL_ORIGIN) return true;
  const host = url.hostname.toLowerCase();
  if (host === 'supabase.co' || host.endsWith('.supabase.co')) return true;
  if (host === 'tosspayments.com' || host.endsWith('.tosspayments.com')) return true;
  return THIRD_PARTY_HOSTS.has(host);
}

function assertAppUrlsAreRelativeOrCanonical(file, source) {
  const urls = source.match(/https?:\/\/[^\s"'`)<>]+/g) || [];
  for (const value of urls) {
    assert.equal(
      isAllowedAbsoluteUrl(value),
      true,
      `${file} has an absolute URL that is neither relative nor the canonical app origin`,
    );
  }
  const protocolRelative = source.match(/(?:href|src|content)\s*=\s*["']\/\/[^"']+/g) || [];
  assert.deepEqual(protocolRelative, [], `${file} has a protocol-relative app URL`);
}

const { policy, listeners } = loadWorkerPolicy();
const origin = CANONICAL_ORIGIN;

test('cache version is the APP_SHELL content hash', () => {
  const expected = expectedCacheVersion(policy.APP_SHELL);
  assert.equal(
    policy.CACHE_VERSION,
    expected,
    `Set CACHE_VERSION in sw.js to ${expected}`,
  );
  assert.match(policy.CACHE_VERSION, /^remember-[0-9a-f]{16}$/);
  assert.equal(readFileSync('sw.js', 'utf8').includes('remember-v25-payment-history'), false);
});

test('every local script and the app shell file exists in APP_SHELL', () => {
  const page = readFileSync('index.html', 'utf8');
  const sources = [...page.matchAll(/<script\s+src="([^"]+)"/g)].map((match) => match[1]);
  for (const src of sources) {
    if (!src.startsWith('./js/') && !src.startsWith('/js/')) continue;
    const path = `/${src.replace(/^\.\//, '')}`;
    assert.equal(policy.APP_SHELL.includes(path), true, `${path} must be precached`);
    readFileSync(shellFile(path));
  }
  for (const shellPath of policy.APP_SHELL) {
    readFileSync(shellFile(shellPath));
  }
  assert.equal(policy.APP_SHELL.includes('/'), true);
  assert.equal(policy.APP_SHELL.includes('/index.html'), true);
  assert.equal(policy.APP_SHELL.includes('/js/billing.js'), true);
});

test('navigation and app source are network-first', () => {
  assert.equal(policy.fetchStrategy(new Request(`${origin}/`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/index.html`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/signup`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/login`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/reset-password`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/js/billing.js`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/js/billing-config.js`)), 'network-first');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/styles.css`)), 'network-first');
  assert.equal(
    policy.fetchStrategy(new Request(`${origin}/?billing=success`)),
    'network-first',
  );
});

test('icons revalidate in the background and API responses are never cached', () => {
  assert.equal(policy.fetchStrategy(new Request(`${origin}/app-icon-192.png`)), 'stale-while-revalidate');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/manifest.json`)), 'stale-while-revalidate');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/sw.js`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/`, { method: 'POST' })), 'bypass');
  assert.equal(
    policy.fetchStrategy(new Request(`${origin}/js/billing.js`, { headers: { Authorization: 'Bearer test' } })),
    'bypass',
  );
  assert.equal(
    policy.fetchStrategy(new Request(`${origin}/app-icon-192.png`, { headers: { Range: 'bytes=0-1' } })),
    'bypass',
  );
  assert.equal(policy.fetchStrategy(new Request(`${origin}/?code=example`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/auth/v1/token`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/rest/v1/members`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/functions/v1/create-checkout`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/api/payments`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request(`${origin}/payments`)), 'bypass');
  assert.equal(policy.fetchStrategy(new Request('https://project.example.supabase.co/rest/v1/members')), 'bypass');
  assert.equal(policy.fetchStrategy(new Request('https://project.example.supabase.co/functions/v1/confirm-toss-payment')), 'bypass');
  assert.equal(policy.fetchStrategy(new Request('https://js.tosspayments.com/v2/standard')), 'bypass');
  assert.equal(policy.fetchStrategy(new Request('https://cdn.jsdelivr.net/npm/example')), 'bypass');
});

test('only a basic non-redirect response may be stored', () => {
  assert.equal(policy.canStore({ ok: true, type: 'basic', redirected: false }), true);
  assert.equal(policy.canStore({ ok: false, type: 'basic', redirected: false }), false);
  assert.equal(policy.canStore({ ok: true, type: 'cors', redirected: false }), false);
  assert.equal(policy.canStore({ ok: true, type: 'opaque', redirected: false }), false);
  assert.equal(policy.canStore({ ok: true, type: 'basic', redirected: true }), false);
  assert.equal(policy.canStore(null), false);
});

test('a new worker takes control and drops old caches', () => {
  const source = readFileSync('sw.js', 'utf8');
  assert.equal(typeof listeners.install, 'object');
  assert.equal(typeof listeners.activate, 'object');
  assert.equal(typeof listeners.fetch, 'object');
  assert.match(source, /skipWaiting\s*\(/);
  assert.match(source, /clients\.claim\s*\(/);
  assert.match(source, /caches\.delete\s*\(/);
  assert.match(source, /REMEMBER_SW_ACTIVATED/);
  assert.match(source, /client\.navigate\s*\(/);
});

test('sw.js is served with no-cache headers', () => {
  const vercel = JSON.parse(readFileSync('vercel.json', 'utf8'));
  const rule = vercel.headers.find((entry) => entry.source === '/sw.js');
  assert.ok(rule, 'vercel.json is missing a /sw.js header rule');
  const cacheControl = rule.headers.find((header) => header.key.toLowerCase() === 'cache-control');
  assert.ok(cacheControl, 'sw.js is missing Cache-Control');
  assert.match(cacheControl.value.toLowerCase(), /\bno-cache\b/);
  assert.match(cacheControl.value.toLowerCase(), /\bno-store\b/);
  assert.doesNotMatch(cacheControl.value, /max-age\s*=\s*[1-9]/);
  assert.doesNotMatch(cacheControl.value.toLowerCase(), /immutable/);

  const appSources = ['/', '/index.html', '/js/(.*)'];
  for (const source of appSources) {
    const appRule = vercel.headers.find((entry) => entry.source === source);
    assert.ok(appRule, `missing cache header for ${source}`);
    const value = appRule.headers.find((header) => header.key.toLowerCase() === 'cache-control').value;
    assert.match(value.toLowerCase(), /\bno-cache\b/);
  }
});

test('the page reloads once when a new worker takes control', () => {
  const page = readFileSync('index.html', 'utf8');
  assert.match(page, /updateViaCache:\s*'none'/);
  assert.match(page, /controllerchange/);
  assert.match(page, /REMEMBER_SW_ACTIVATED/);
  assert.match(page, /REMEMBER_SW_RELOADING/);
  assert.match(page, /remember-sw-reload-at/);
  assert.match(page, /serviceWorker\.register\(\s*'\/sw\.js'/);
});

test('manifest and in-app URLs stay relative or canonical', () => {
  for (const file of ['manifest.json', 'manifest.webmanifest']) {
    const manifest = JSON.parse(readFileSync(file, 'utf8'));
    for (const value of [manifest.start_url, manifest.scope, manifest.id]) {
      assert.equal(value, '/', `${file} navigation target must stay relative`);
    }
    for (const shortcut of manifest.shortcuts || []) {
      assert.equal(shortcut.url, '/', `${file} shortcut must stay relative`);
    }
    assertAppUrlsAreRelativeOrCanonical(file, readFileSync(file, 'utf8'));
  }

  const files = [
    'index.html',
    'sw.js',
    'js/config.js',
    'js/billing-config.js',
    'js/billing.js',
    'js/supabase-service.js',
  ];
  for (const file of files) {
    assertAppUrlsAreRelativeOrCanonical(file, readFileSync(file, 'utf8'));
  }
});
