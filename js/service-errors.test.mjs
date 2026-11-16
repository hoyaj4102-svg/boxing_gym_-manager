import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

function loadService(translate) {
  const window = { rememberT: translate };
  vm.runInNewContext(readFileSync('js/supabase-service.js', 'utf8'), { window }, {
    filename: 'js/supabase-service.js'
  });
  return window.SweatManagerDB;
}

test('service errors use i18n keys and the current translator', async () => {
  const db = loadService((key) => `translated:${key}`);
  await assert.rejects(() => db.fetchMembers(), (error) => {
    assert.equal(error.code, 'serviceLoginRequired');
    assert.equal(error.message, 'translated:serviceLoginRequired');
    return true;
  });
  await assert.rejects(() => db.signUp({}), (error) => {
    assert.equal(error.code, 'serviceNotConfigured');
    assert.equal(error.message, 'translated:serviceNotConfigured');
    return true;
  });
  await assert.rejects(() => db.resetPassword('person@example.com', 'en'), (error) => {
    assert.equal(error.code, 'serviceNotConfigured');
    return true;
  });
});

test('the service no longer throws hardcoded Korean messages', () => {
  const source = readFileSync('js/supabase-service.js', 'utf8');
  assert.equal(source.includes('프로필이 없습니다'), false);
  assert.equal(source.includes('체육관 정보를 찾을 수 없습니다'), false);
  assert.equal(source.includes('Supabase가 설정되지 않았습니다'), false);
  assert.equal(source.includes('로그인이 필요합니다'), false);
  assert.match(source, /serviceError\('serviceProfileMissing'\)/);
  assert.match(source, /serviceError\('serviceGymMissing'\)/);
});
