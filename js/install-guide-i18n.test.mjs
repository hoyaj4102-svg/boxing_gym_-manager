import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const page = readFileSync('index.html', 'utf8');
const languageSource = readFileSync('js/language.js', 'utf8');
const HANGUL = /[가-힣]/;

function translations() {
  const start = page.indexOf('    const TRANSLATIONS = ');
  const end = page.indexOf('    let currentLanguage');
  assert.ok(start > 0 && end > start);
  const context = {};
  vm.runInNewContext(`${page.slice(start, end)}\nthis.TRANSLATIONS = TRANSLATIONS;`, vm.createContext(context));
  return context.TRANSLATIONS;
}

function installGuideSteps() {
  const start = page.indexOf('    const INSTALL_GUIDE_STEPS = ');
  const end = page.indexOf('    function loadLegacyLocalMembers()');
  assert.ok(start > 0 && end > start);
  const context = {};
  vm.runInNewContext(`${page.slice(start, end)}\nthis.INSTALL_GUIDE_STEPS = INSTALL_GUIDE_STEPS;`, vm.createContext(context));
  return context.INSTALL_GUIDE_STEPS;
}

const dictionaries = translations();
const steps = installGuideSteps();

function installAndMockKeys() {
  const keys = new Set();
  for (const dictionary of Object.values(dictionaries)) {
    for (const key of Object.keys(dictionary)) {
      if (key.startsWith('install') || key.startsWith('mock')) keys.add(key);
    }
  }
  for (const platform of Object.values(steps)) {
    for (const step of platform) {
      keys.add(step.titleKey);
      keys.add(step.copyKey);
    }
  }
  return [...keys].sort();
}

test('the install guide has iPhone and Android steps wired through translation keys', () => {
  assert.deepEqual(Object.keys(steps), ['iphone', 'android']);
  assert.equal(steps.iphone.length, 4);
  assert.equal(steps.android.length, 3);
  for (const [platform, list] of Object.entries(steps)) {
    list.forEach((step, index) => {
      assert.equal(typeof step.titleKey, 'string', `${platform} ${index} titleKey`);
      assert.equal(typeof step.copyKey, 'string', `${platform} ${index} copyKey`);
      assert.match(step.titleKey, /^installStep/);
      assert.match(step.copyKey, /^installStep/);
    });
  }
});

test('every install-guide and mock string exists in each language and English has no Korean', () => {
  const keys = installAndMockKeys();
  assert.ok(keys.length >= 20, `expected a full install/mock key set, got ${keys.length}`);
  for (const language of Object.keys(dictionaries)) {
    for (const key of keys) {
      const value = dictionaries[language][key];
      assert.equal(typeof value, 'string', `${language}.${key}`);
      assert.notEqual(value, '', `${language}.${key}`);
      if (language === 'en' || language !== 'ko') {
        assert.doesNotMatch(value, HANGUL, `${language}.${key}`);
      }
    }
  }
});

test('the modal and each mockup refresh from t() when the resolved language changes', () => {
  assert.match(page, /function openInstallGuide/);
  assert.match(page, /installGuideTitle'\)\.textContent = t\('installGuideTitle'\)/);
  assert.match(page, /function renderInstallGuideStep/);
  assert.match(page, /installStepTitle'\)\.textContent = t\(current\.titleKey\)/);
  assert.match(page, /installStepCopy'\)\.textContent = t\(current\.copyKey\)/);
  assert.match(page, /if \(installSteps && !installSteps\.hidden\) renderInstallGuideStep\(\)/);
  const mockupStart = page.indexOf('function getInstallMockup');
  const mockupEnd = page.indexOf('function mockReMemberPage');
  const mockup = page.slice(mockupStart, mockupEnd);
  assert.ok(mockup.length > 200);
  assert.equal(HANGUL.test(mockup), false, 'getInstallMockup must not hard-code Korean');
  assert.match(mockup, /\$\{t\('mockShare'\)\}/);
  assert.match(mockup, /\$\{t\('mockAddToHome'\)\}/);
  assert.match(mockup, /\$\{t\('mockInstallApp'\)\}/);
  assert.match(mockup, /\$\{t\('mockInstallButton'\)\}/);
});

test('resolved English from the browser is what the install guide will follow', () => {
  const window = {};
  vm.runInNewContext(languageSource, { window, URL, URLSearchParams }, { filename: 'js/language.js' });
  const language = window.RememberLanguage;
  const resolved = language.resolveLanguage({
    search: '',
    sessionKnown: true,
    browserLanguages: ['en-US', 'en']
  });
  assert.equal(resolved.language, 'en');
  assert.equal(resolved.persist, false);
  assert.match(page, /browserLanguages:\s*browserLanguages\(\)/);
  assert.match(page, /currentLanguage = resolved\.language/);
});
