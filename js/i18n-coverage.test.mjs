import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const page = readFileSync('index.html', 'utf8');

function translations() {
  const start = page.indexOf('    const TRANSLATIONS = ');
  const end = page.indexOf('    let currentLanguage');
  assert.ok(start > 0 && end > start);
  const context = {};
  vm.runInNewContext(`${page.slice(start, end)}\nthis.TRANSLATIONS = TRANSLATIONS;`, vm.createContext(context));
  return context.TRANSLATIONS;
}

function lookup(dictionaries, language, key) {
  const dictionary = dictionaries[language] || dictionaries.en || dictionaries.ko;
  return (dictionary && dictionary[key])
    || (dictionaries.en && dictionaries.en[key])
    || (dictionaries.ko && dictionaries.ko[key])
    || key;
}

const dictionaries = translations();
const addedKeys = [
  'registerHint',
  'memberListHint',
  'authPhonePlaceholder',
  'phonePlaceholder',
  'installGuideTitle',
  'installGuideDescription',
  'installGuideIphoneButton',
  'installGuideAndroidButton',
  'installGuideLaterButton',
  'installGuideSettingsButton',
  'installGuideExampleLabel',
  'installGuideBackButton',
  'installGuideNextButton',
  'installGuideDoneButton',
  'installGuideCompleteTitle',
  'installGuideCompleteBody',
  'installGuideIphoneHeading',
  'installGuideAndroidHeading',
  'installStepKicker',
  'installStepIphone1Title',
  'installStepIphone1Copy',
  'installStepIphone4Copy',
  'installStepAndroid1Title',
  'installStepAndroid3Copy',
  'mockShare',
  'mockAddToHome',
  'mockInstallButton',
  'serviceProfileMissing',
  'serviceGymMissing',
  'serviceNotConfigured',
  'serviceLoginRequired'
];

test('every locale has the newly translated keys', () => {
  for (const language of Object.keys(dictionaries)) {
    for (const key of addedKeys) {
      assert.equal(typeof dictionaries[language][key], 'string', `${language}.${key}`);
      assert.notEqual(dictionaries[language][key], '', `${language}.${key}`);
    }
  }
});

test('the install guide follows each app language', () => {
  const installKeys = addedKeys.filter((key) => key.startsWith('install') || key.startsWith('mock'));
  const seen = new Set();
  for (const language of Object.keys(dictionaries)) {
    for (const key of installKeys) {
      const value = dictionaries[language][key];
      assert.equal(typeof value, 'string', `${language}.${key}`);
      assert.notEqual(value, '', `${language}.${key}`);
      if (language !== 'ko') assert.doesNotMatch(value, /[가-힣]/, `${language}.${key}`);
    }
    assert.equal(dictionaries[language].installStepKicker.includes('{count}'), true, language);
    seen.add(dictionaries[language].installGuideSettingsButton);
    if (language !== 'ko') assert.doesNotMatch(dictionaries[language].registerHint, /[가-힣]/);
  }
  assert.equal(seen.size, Object.keys(dictionaries).length);
  assert.equal(dictionaries.ko.installGuideSettingsButton, '📱 휴대폰에 앱처럼 설치하기');
  assert.equal(dictionaries.ko.installGuideLaterButton, '나중에 하기');
  assert.equal(dictionaries.ko.installStepKicker, 'STEP {count}');
  assert.equal(dictionaries.en.installGuideSettingsButton, '📱 Install it like an app on your phone');
  assert.equal(dictionaries.en.installStepKicker, 'STEP {count}');
  assert.equal(dictionaries.es.installGuideLaterButton, 'Más tarde');
  assert.equal(dictionaries.es.installStepKicker, 'PASO {count}');
  assert.equal(dictionaries.ru.installGuideLaterButton, 'Позже');
  assert.equal(dictionaries.ru.installStepKicker, 'ШАГ {count}');
  assert.equal(dictionaries.mn.installGuideLaterButton, 'Дараа');
  assert.equal(dictionaries.mn.mockShare, '⇧ Хуваалцах');
  assert.equal(dictionaries.zh.installGuideExampleLabel, '示例画面');
  assert.equal(dictionaries.zh.installStepKicker, '步骤 {count}');
  assert.equal(dictionaries.hi.installGuideSettingsButton, '📱 फ़ोन पर ऐप की तरह इंस्टॉल करें');
  assert.equal(dictionaries.fr.installGuideLaterButton, 'Plus tard');
  assert.equal(dictionaries.fr.installStepKicker, 'ÉTAPE {count}');
  assert.equal(dictionaries.ko.registerHint, '빠른 등록');
  assert.equal(dictionaries.ko.memberListHint, '검색 및 상세');
  assert.equal(dictionaries.en.registerHint, 'Quick add');
  assert.equal(dictionaries.en.memberListHint, 'Search and details');
  assert.match(page, /if \(installSteps && !installSteps\.hidden\) renderInstallGuideStep\(\)/);
  assert.match(page, /\.install-guide-intro\[hidden\],\s*\.install-guide-step\[hidden\]\s*\{[^}]*display:\s*none;/);
  assert.equal(page.includes('① 아래 공유 버튼을 눌러주세요.'), false);
});

test('a missing locale key falls back to English before Korean', () => {
  const value = lookup(dictionaries, 'es', 'authPasswordTooShort');
  assert.equal(value, dictionaries.en.authPasswordTooShort);
  assert.notEqual(value, dictionaries.ko.authPasswordTooShort);
});

test('phone placeholders follow the language', () => {
  assert.equal(dictionaries.ko.phonePlaceholder, '010-1234-5678');
  assert.equal(dictionaries.en.phonePlaceholder, '555-010-1234');
  assert.notEqual(dictionaries.es.phonePlaceholder, dictionaries.ko.phonePlaceholder);
  assert.notEqual(dictionaries.zh.authPhonePlaceholder, dictionaries.ko.authPhonePlaceholder);
  assert.match(page, /id="authGymPhone"[^>]*data-i18n-placeholder="authPhonePlaceholder"/);
  assert.match(page, /id="phone"[^>]*data-i18n-placeholder="phonePlaceholder"/);
  assert.match(page, /id="editPhone"[^>]*data-i18n-placeholder="phonePlaceholder"/);
});

test('dashboard hints and install steps are translated through keys', () => {
  assert.match(page, /data-i18n="registerHint"/);
  assert.match(page, /data-i18n="memberListHint"/);
  assert.match(page, /titleKey: 'installStepIphone1Title'/);
  assert.match(page, /copyKey: 'installStepAndroid3Copy'/);
  assert.match(page, /\$\{t\('mockShare'\)\}/);
  assert.match(page, /\$\{t\('mockInstallButton'\)\}/);
  const mockupStart = page.indexOf('function getInstallMockup');
  const mockupEnd = page.indexOf('function mockReMemberPage');
  assert.equal(/[가-힣]/.test(page.slice(mockupStart, mockupEnd)), false);
});
