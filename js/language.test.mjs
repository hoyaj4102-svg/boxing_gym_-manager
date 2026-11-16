import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function loadLanguage() {
  const window = {};
  vm.runInNewContext(readFileSync('js/language.js', 'utf8'), { window, URL, URLSearchParams }, {
    filename: 'js/language.js'
  });
  return window.RememberLanguage;
}

const language = loadLanguage();

function plain(value) {
  return JSON.parse(JSON.stringify(value));
}
const CANONICAL = 'https://boxing-gym-manager.vercel.app';
const ALT = 'https://remember-gym.vercel.app';

test('query language wins and is saved, including over storage, account, and utm', () => {
  const resolved = language.resolveLanguage({
    search: '?lang=en&utm_source=threads&code=example',
    stored: 'ko',
    accountLocale: 'fr',
    sessionKnown: true
  });
  assert.deepEqual(plain(resolved), { language: 'en', persist: true, source: 'query' });
  assert.equal(language.resolveLanguage({ search: '?lang=ES' }).language, 'es');
});

test('an unsupported query language is ignored', () => {
  const resolved = language.resolveLanguage({
    search: '?lang=de&utm_source=threads',
    sessionKnown: true
  });
  assert.deepEqual(plain(resolved), { language: 'ko', persist: false, source: 'default' });
});

test('a saved choice wins over the account locale and over X or Threads', () => {
  const resolved = language.resolveLanguage({
    search: '?utm_source=x',
    stored: 'fr',
    accountLocale: 'en',
    sessionKnown: true
  });
  assert.deepEqual(plain(resolved), { language: 'fr', persist: false, source: 'storage' });
});

test('account locale is used only when nothing is saved and the session is known', () => {
  const resolved = language.resolveLanguage({
    search: '?utm_source=x',
    stored: null,
    accountLocale: 'ko',
    sessionKnown: true
  });
  assert.deepEqual(plain(resolved), { language: 'ko', persist: false, source: 'account' });
  assert.equal(
    language.resolveLanguage({
      search: '?utm_source=x',
      accountLocale: 'en',
      sessionKnown: false
    }).source,
    'pending'
  );
  assert.equal(language.accountLocale({ user_metadata: { locale: 'EN' } }), 'en');
  assert.equal(language.accountLocale({ user_metadata: { locale: 'de' } }), null);
  assert.equal(language.accountLocale({ user_metadata: {} }), null);
});

test('utm_source=x selects English and saves only after the session is known', () => {
  assert.deepEqual(
    plain(language.resolveLanguage({ search: '?utm_source=X', sessionKnown: true })),
    { language: 'en', persist: true, source: 'utm' }
  );
  assert.deepEqual(
    plain(language.resolveLanguage({ search: '?utm_source=x&utm_medium=social', sessionKnown: false })),
    { language: 'en', persist: false, source: 'pending' }
  );
});

test('Threads and every other visit stay Korean and are not saved', () => {
  for (const search of ['', '?utm_source=threads', '?utm_source=twitter', '?utm_source=instagram']) {
    assert.deepEqual(
      plain(language.resolveLanguage({ search, sessionKnown: true })),
      { language: 'ko', persist: false, source: 'default' },
      search || '(no query)'
    );
    assert.equal(language.resolveLanguage({ search, sessionKnown: false }).persist, false);
  }
});

test('auth redirects keep the chosen language on the current origin', () => {
  assert.equal(
    language.redirectUrl(CANONICAL, '/login', 'en'),
    `${CANONICAL}/login?lang=en`
  );
  assert.equal(
    language.redirectUrl(ALT, '/reset-password', 'ko'),
    `${ALT}/reset-password?lang=ko`
  );
  assert.equal(
    language.redirectUrl(CANONICAL, '/login', 'nope'),
    `${CANONICAL}/login`
  );
});

test('cleaning an auth URL drops tokens but keeps the chosen language', () => {
  assert.equal(
    language.cleanAuthPath('/reset-password', '?code=example&lang=en', 'ko'),
    '/reset-password?lang=en'
  );
  assert.equal(
    language.cleanAuthPath('/login', '?access_token=example&refresh_token=example', 'fr'),
    '/login?lang=fr'
  );
  assert.equal(language.cleanAuthPath('/login', '', null), '/login');
  assert.equal(
    language.cleanAuthPath('/reset-password?code=example', '?lang=zh', null),
    '/reset-password?lang=zh'
  );
});

test('the page wires the selector, redirects, and account locale update', () => {
  const page = readFileSync('index.html', 'utf8');
  const service = readFileSync('js/supabase-service.js', 'utf8');
  const worker = readFileSync('sw.js', 'utf8');

  assert.match(page, /id="authLanguageSelect"/);
  assert.match(page, /RememberLanguage\.resolveLanguage/);
  assert.match(page, /RememberLanguage\.cleanAuthPath/);
  assert.match(page, /locale:\s*currentLanguage/);
  assert.match(page, /resetPassword\(email,\s*currentLanguage\)/);
  assert.match(page, /syncAccount:\s*true/);
  assert.match(service, /emailRedirectTo/);
  assert.match(service, /locale/);
  assert.match(service, /updateLocale/);
  assert.match(service, /never used for authorization/i);
  assert.match(worker, /\/js\/language\.js/);
  assert.match(page, /src="\.\/js\/language\.js"/);
});
