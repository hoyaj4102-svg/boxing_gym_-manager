import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createRequire } from 'node:module';
import test from 'node:test';

function readRepo(relativePath) {
  return readFileSync(new URL(`../${relativePath}`, import.meta.url), 'utf8');
}

const require = createRequire(import.meta.url);
const { initialAuthMode, isAuthScreenRoute, applyPublicEntryVisibility } = require('./public-entry.js');

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');

function landingMarkup() {
  const start = html.indexOf('id="publicLanding"');
  const end = html.indexOf('id="authGate"');
  assert.ok(start !== -1 && end !== -1 && start < end, 'landing markup must precede the auth gate');
  return html.slice(start, end);
}

test('logged-out home is the landing route and auth paths stay on the auth card', () => {
  assert.equal(isAuthScreenRoute({ pathname: '/' }), false);
  assert.equal(isAuthScreenRoute({ pathname: '/index.html' }), false);
  assert.equal(isAuthScreenRoute({ pathname: '/login' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/signup' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/reset-password' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', search: '?auth=signup' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', search: '?auth=login' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', search: '?reset=1' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', search: '?code=abc' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', hash: '#access_token=abc' }), true);
  assert.equal(isAuthScreenRoute({ pathname: '/', hash: '#type=recovery' }), true);
});

test('initial auth mode matches the existing signup, login, and reset routes', () => {
  assert.equal(initialAuthMode({ pathname: '/' }), 'login');
  assert.equal(initialAuthMode({ pathname: '/login' }), 'login');
  assert.equal(initialAuthMode({ pathname: '/signup' }), 'signup');
  assert.equal(initialAuthMode({ pathname: '/SIGNUP' }), 'signup');
  assert.equal(initialAuthMode({ pathname: '/', search: '?auth=signup' }), 'signup');
  assert.equal(initialAuthMode({ pathname: '/', search: '?mode=signup' }), 'signup');
  assert.equal(initialAuthMode({ pathname: '/', search: '?signup=1' }), 'signup');
  assert.equal(initialAuthMode({ pathname: '/reset-password' }), 'recovery');
  assert.equal(initialAuthMode({ pathname: '/', search: '?auth=reset' }), 'reset');
  assert.equal(initialAuthMode({ pathname: '/', search: '?reset' }), 'reset');
});

test('visibility helper shows the landing only off the auth routes', () => {
  const doc = {
    elements: {
      publicLanding: { hidden: false },
      authGate: { hidden: true }
    },
    getElementById(id) {
      return this.elements[id] || null;
    }
  };

  assert.equal(applyPublicEntryVisibility(doc, { pathname: '/' }), false);
  assert.equal(doc.elements.publicLanding.hidden, false);
  assert.equal(doc.elements.authGate.hidden, true);

  assert.equal(applyPublicEntryVisibility(doc, { pathname: '/signup' }), true);
  assert.equal(doc.elements.publicLanding.hidden, true);
  assert.equal(doc.elements.authGate.hidden, false);
});

test('landing headline and signup CTA do not point at payment', () => {
  const landing = landingMarkup();
  assert.match(landing, /<h1[^>]*>부담 없는 회원재등록 관리앱<\/h1>/);
  assert.match(
    landing,
    /<a[^>]*id="landingSignupLink"[^>]*href="\/signup"[^>]*>무료로 써보기<\/a>/
  );
  assert.match(landing, /<a[^>]*href="\/login"[^>]*>로그인<\/a>/);

  const forbidden = [
    'toss',
    'pricing',
    'billing',
    'subscribe',
    'start-billing-auth',
    'startSubscribe',
    '구독',
    '/payment'
  ];
  for (const word of forbidden) {
    assert.equal(
      landing.toLowerCase().includes(word.toLowerCase()),
      false,
      `landing must not mention ${word}`
    );
  }

  assert.doesNotMatch(landing, /data-i18n="brandTagline"/);
});

test('login and signup share the landing tagline', () => {
  const phrase = '부담 없는 회원재등록 관리앱';
  assert.match(html, new RegExp(`id="authGate"[\\s\\S]*data-i18n="brandTagline">${phrase}`));
  assert.match(html, new RegExp(`brandTagline: '${phrase}'`));
  assert.equal((html.match(/재등록 관리에 특화된 가장 간단한 회비관리앱/g) || []).length, 0);

  const auth = html.slice(html.indexOf('id="authGate"'), html.indexOf('id="appShell"'));
  assert.equal((html.match(/data-i18n="brandTagline">부담 없는 회원재등록 관리앱/g) || []).length, 2);
  assert.equal(auth.includes(phrase), true);
  assert.equal(auth.includes('가장'), false);
  assert.equal(auth.toLowerCase().includes('crm'), false);

  assert.match(html, /<h1[^>]*>부담 없는 회원재등록 관리앱<\/h1>/);
  assert.match(html, /id="landingSignupLink"[^>]*href="\/signup"[^>]*>무료로 써보기<\/a>/);
});

test('docs and PWA metadata use the screen tagline', () => {
  const phrase = '부담 없는 회원재등록 관리앱';
  const files = ['README.md', 'manifest.json', 'manifest.webmanifest', 'SUPABASE_SETUP.md'];
  for (const file of files) {
    const source = readRepo(file);
    assert.equal(source.includes(phrase), true, file);
    assert.equal(source.includes('재등록 관리에 특화된 가장 간단한 회비관리앱'), false, file);
    assert.equal(source.includes('회비관리앱'), false, file);
    assert.equal(source.includes('가장'), false, file);
    assert.equal(source.toLowerCase().includes('crm'), false, file);
  }

  for (const file of ['manifest.json', 'manifest.webmanifest']) {
    const manifest = JSON.parse(readRepo(file));
    assert.equal(manifest.name, `re;member — ${phrase}`);
    assert.equal(manifest.description.startsWith(phrase), true);
  }
});

test('a logged-out first visit does not show the sign-out notice', () => {
  const start = html.indexOf('SweatManagerDB.onAuthStateChange');
  const end = html.indexOf('isBootstrapping = false;', start);
  const listener = html.slice(start, end);
  assert.match(listener, /else if \(event === 'SIGNED_OUT'\)/);
  assert.doesNotMatch(listener, /else \{\s*const message = pendingSignedOutMessage/);
});

test('signed-in home still opens the app shell and hides the landing', () => {
  assert.match(html, /function showAppShell\(\) \{[\s\S]*?getElementById\('publicLanding'\)\.hidden = true/);
  assert.match(html, /function showAppShell\(\) \{[\s\S]*?getElementById\('authGate'\)\.hidden = true/);
  assert.match(html, /async function handleSignedIn\(sessionUser\) \{[\s\S]*?showAppShell\(\)/);
  assert.match(html, /session\?\.user\) \{\s*await handleSignedIn\(session\.user\)/);
});
