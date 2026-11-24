import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function loadAcquisition() {
  const window = {};
  vm.runInNewContext(readFileSync('js/acquisition.js', 'utf8'), {
    window,
    URL,
    URLSearchParams,
    Date,
    JSON,
    Object,
    Set,
    Number,
    String,
    Boolean
  }, { filename: 'js/acquisition.js' });
  return window.RememberAcquisition;
}

const acquisition = loadAcquisition();

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}

function memoryStorage() {
  const data = new Map();
  return {
    getItem(key) {
      return data.has(key) ? data.get(key) : null;
    },
    setItem(key, value) {
      data.set(key, String(value));
    },
    removeItem(key) {
      data.delete(key);
    }
  };
}

const NOW = Date.parse('2026-11-22T12:00:00.000Z');

test('a threads landing stores safe fields and not the raw query or referrer URL', () => {
  const storage = memoryStorage();
  const result = acquisition.captureFirstVisit({
    search: '?utm_source=threads&utm_medium=social&utm_campaign=launch&utm_content=bio&utm_term=boxing&email=hidden@example.invalid',
    referrer: 'https://user:secret@l.threads.net/private/path?email=hidden@example.invalid',
    pathname: '/signup',
    pageHost: 'boxing-gym-manager.vercel.app',
    now: NOW,
    storage
  });

  assert.equal(result.stored, true);
  assert.deepEqual(plain(result.record), {
    utm_source: 'threads',
    utm_medium: 'social',
    utm_campaign: 'launch',
    utm_content: 'bio',
    utm_term: 'boxing',
    referrer_domain: 'l.threads.net',
    landing_path: '/signup',
    captured_at: '2026-11-22T12:00:00.000Z'
  });

  const raw = storage.getItem(acquisition.STORAGE_KEY);
  assert.equal(raw.includes('?'), false);
  assert.equal(raw.includes('utm_source='), false);
  assert.equal(raw.includes('secret'), false);
  assert.equal(raw.includes('private'), false);
  assert.equal(raw.includes('@'), false);
  assert.equal(raw.includes('email'), false);
  assert.equal(raw.includes('hidden'), false);
  const stored = JSON.parse(raw);
  assert.equal(stored.expires_at - NOW, acquisition.TTL_MS);
  assert.equal(acquisition.TTL_MS, 30 * 60 * 1000);
});

test('the first visit wins until the short retention expires', () => {
  const storage = memoryStorage();
  acquisition.captureFirstVisit({
    search: '?utm_source=threads',
    referrer: 'https://l.threads.net/',
    pathname: '/',
    pageHost: 'remember-gym.vercel.app',
    now: NOW,
    storage
  });
  const second = acquisition.captureFirstVisit({
    search: '?utm_source=x&utm_medium=later',
    referrer: 'https://other.example/path',
    pathname: '/login',
    pageHost: 'remember-gym.vercel.app',
    now: NOW + 60 * 1000,
    storage
  });
  assert.equal(second.stored, false);
  assert.equal(second.record.utm_source, 'threads');
  assert.equal(second.record.landing_path, '/');
  assert.equal(second.record.referrer_domain, 'l.threads.net');

  const expired = acquisition.captureFirstVisit({
    search: '?utm_source=x',
    referrer: '',
    pathname: '/login',
    pageHost: 'remember-gym.vercel.app',
    now: NOW + acquisition.TTL_MS + 1,
    storage
  });
  assert.equal(expired.stored, true);
  assert.equal(expired.record.utm_source, 'x');
  assert.equal(expired.record.landing_path, '/login');
  assert.equal(expired.record.referrer_domain, undefined);
});

test('a visit without utm keeps the landing path and drops invalid or private values', () => {
  const storage = memoryStorage();
  const result = acquisition.captureFirstVisit({
    search: '?utm_source=%3Cscript%3E&utm_medium=social%20post&utm_campaign=' + 'a'.repeat(65) + '&lang=en',
    referrer: 'https://203.0.113.10/admin?token=secret',
    pathname: '/?utm_source=threads',
    pageHost: 'boxing-gym-manager.vercel.app',
    now: NOW,
    storage
  });
  assert.equal(result.stored, false);
  assert.equal(result.record, null);
  assert.equal(storage.getItem(acquisition.STORAGE_KEY), null);

  const direct = acquisition.captureFirstVisit({
    search: '',
    referrer: 'https://boxing-gym-manager.vercel.app/signup?utm_source=threads',
    pathname: '/',
    pageHost: 'boxing-gym-manager.vercel.app',
    now: NOW,
    storage
  });
  assert.equal(direct.stored, true);
  assert.deepEqual(plain(direct.record), {
    landing_path: '/',
    captured_at: '2026-11-22T12:00:00.000Z'
  });
  const raw = storage.getItem(acquisition.STORAGE_KEY);
  assert.equal(raw.includes('utm_source'), false);
  assert.equal(raw.includes('threads'), false);
  assert.equal(raw.includes('?'), false);
});

test('signup payload keeps safe tokens only', () => {
  const payload = acquisition.forSignup({
    utm_source: ' threads ',
    utm_medium: 'owner@example.invalid',
    utm_campaign: 'launch',
    utm_content: 'bad value',
    utm_term: 'boxing',
    referrer_domain: 'https://l.threads.net/path?q=1',
    landing_path: '/signup',
    captured_at: '2026-11-22T12:00:00.000Z',
    email: 'owner@example.invalid',
    ip: '203.0.113.10',
    query: '?utm_source=threads',
    fingerprint: 'device-1'
  }, NOW);
  assert.deepEqual(plain(payload), {
    utm_source: 'threads',
    utm_campaign: 'launch',
    utm_term: 'boxing',
    landing_path: '/signup',
    captured_at: '2026-11-22T12:00:00.000Z'
  });
  assert.equal(JSON.stringify(payload).includes('@'), false);
  assert.equal(JSON.stringify(payload).includes('203.0.113.10'), false);
  assert.equal(JSON.stringify(payload).includes('?'), false);
  assert.equal(JSON.stringify(payload).includes('fingerprint'), false);
});

test('signup read clears an expired or unexpected client record', () => {
  const storage = memoryStorage();
  storage.setItem(acquisition.STORAGE_KEY, JSON.stringify({
    utm_source: 'threads',
    landing_path: '/',
    captured_at: '2026-11-22T12:00:00.000Z',
    expires_at: NOW + 1000,
    query: '?utm_source=threads'
  }));
  assert.equal(acquisition.readForSignup({ storage, now: NOW }), null);
  assert.equal(storage.getItem(acquisition.STORAGE_KEY), null);

  storage.setItem(acquisition.STORAGE_KEY, JSON.stringify({
    utm_source: 'threads',
    landing_path: '/',
    captured_at: '2026-11-22T12:00:00.000Z',
    expires_at: NOW - 1
  }));
  assert.equal(acquisition.readForSignup({ storage, now: NOW }), null);
  assert.equal(storage.getItem(acquisition.STORAGE_KEY), null);
});

test('the page captures on boot and sends the stored record only after signup', () => {
  const html = readFileSync('index.html', 'utf8');
  const service = readFileSync('js/supabase-service.js', 'utf8');
  const language = readFileSync('js/language.js', 'utf8');

  assert.match(html, /<script src="\.\/js\/acquisition\.js"><\/script>/);
  assert.match(html, /function captureSignupAcquisition\(\)/);
  assert.match(html, /bootstrapLanguage\(\);\s*captureSignupAcquisition\(\);/);
  const signupStart = html.indexOf("if (authMode === 'signup')");
  const signupEnd = html.indexOf('await SweatManagerDB.signIn', signupStart);
  const signup = html.slice(signupStart, signupEnd);
  assert.match(signup, /RememberAcquisition\.readForSignup/);
  assert.match(signup, /acquisition/);
  assert.match(signup, /RememberAcquisition\.clear\(window\.sessionStorage\)/);
  assert.equal(signup.includes('location.search'), false);
  assert.equal(signup.includes('document.referrer'), false);
  assert.equal(signup.includes('email:'), false);

  assert.match(service, /helper\.forSignup\(acquisition\)/);
  assert.equal(service.includes('location.search'), false);
  assert.equal(service.includes('document.referrer'), false);
  assert.match(language, /Threads and every other source stay Korean/);
});

test('migration text blocks anon writes and does not add an email column', () => {
  const migration = readFileSync('supabase/p1_30_signup_acquisition.sql', 'utf8');
  const rollback = readFileSync('supabase/p1_30_signup_acquisition_rollback.sql', 'utf8');
  assert.match(migration, /enable row level security/);
  assert.match(migration, /revoke all on table public\.signup_acquisitions from anon/);
  assert.match(migration, /grant select on table public\.signup_acquisitions to authenticated/);
  assert.match(migration, /grant select on table public\.signup_acquisitions to service_role/);
  assert.equal(/\bgrant\s+(insert|update|delete)\b/i.test(migration), false);
  assert.equal(/\bemail\s+text\b/i.test(migration), false);
  assert.equal(/\bip_address\s+text\b/i.test(migration), false);
  assert.equal(/\bfingerprint\s+text\b/i.test(migration), false);
  assert.match(migration, /create table if not exists public\.signup_acquisitions/);
  assert.match(rollback, /drop table if exists public\.signup_acquisitions/);
  assert.match(rollback, /drop trigger if exists on_auth_user_created_acquisition/);
});
