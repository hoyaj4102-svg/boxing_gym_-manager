import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import { createRequire } from 'node:module';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const require = createRequire(import.meta.url);
const policy = require('./password-policy.js');
const dir = path.dirname(fileURLToPath(import.meta.url));
const list = readFileSync(path.join(dir, 'common-passwords.txt'), 'utf8')
  .split(/\n/)
  .map((line) => line.trim())
  .filter(Boolean);

test('the bundled list has about 1000 unique lowercase passwords', () => {
  assert.equal(new Set(list).size, list.length);
  assert.equal(policy.COMMON_COUNT, list.length);
  assert.ok(list.length >= 1000 && list.length <= 1200, list.length);
  assert.equal(list.includes('password'), true);
  assert.equal(list.includes('123456'), true);
  assert.equal(list.includes('비밀번호'), true);
  assert.equal(list.includes('1q2w3e4r5t'), true);
});

test('new passwords must be 10+ characters with a letter and a number', () => {
  assert.equal(policy.validate('short').reason, 'too_short');
  assert.equal(policy.validate('short').key, 'authPasswordTooShort');
  assert.equal(policy.validate('abcdefghij').reason, 'need_letter_and_number');
  assert.equal(policy.validate('1234567890').reason, 'need_letter_and_number');
  assert.equal(policy.validate('가나다라마바사아자차').reason, 'need_letter_and_number');
  assert.equal(policy.validate('a'.repeat(201)).reason, 'too_long');
  assert.equal(policy.validate('우리동네노란가방17').ok, true);
  assert.equal(policy.validate('lakehouse42').ok, true);
});

test('very common passwords and the email local-part are rejected', () => {
  assert.equal(policy.validate('1q2w3e4r5t').reason, 'too_common');
  assert.equal(policy.validate('1Q2W3E4R5T').reason, 'too_common');
  assert.equal(policy.validate('비밀번호1234', { email: 'owner@example.com' }).ok, false);
  assert.equal(
    policy.validate('minsu.kim99', { email: 'Minsu.Kim@example.com' }).reason,
    'contains_email'
  );
  // Local-parts shorter than 3 characters are not used, so "ab" accounts still work.
  assert.equal(policy.validate('ab12345678', { email: 'ab@example.com' }).ok, true);
  // Login is not validated here; an older 6-character password is only rejected when set.
  assert.equal(policy.validate('abc123').reason, 'too_short');
});

test('index.html and the service check new passwords with the shared policy', () => {
  const page = readFileSync('index.html', 'utf8');
  const service = readFileSync('js/supabase-service.js', 'utf8');
  const worker = readFileSync('sw.js', 'utf8');
  assert.match(page, /src="\.\/js\/password-policy\.js"/);
  assert.match(page, /RememberPasswordPolicy\.validate/);
  assert.match(service, /RememberPasswordPolicy/);
  assert.match(service, /assertNewPassword/);
  assert.match(worker, /\/js\/password-policy\.js/);
  assert.equal(page.includes("password.length < 6"), false);
});
