import { readFileSync } from 'node:fs';

const identity = readFileSync('js/business-identity.js', 'utf8');
const consent = readFileSync('js/billing-consent.js', 'utf8');
const migration = readFileSync('supabase/p1_17_billing_consent.sql', 'utf8');
const index = readFileSync('index.html', 'utf8');
const pages = ['legal/terms.html', 'legal/privacy.html', 'legal/refund.html']
  .map((file) => readFileSync(file, 'utf8'));

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exitCode = 1;
  }
}

for (const token of [
  '[상호 미기재]',
  '[사업자등록번호 미기재]',
  '[대표자 미기재]',
  '[주소 미기재]',
  '[전화 미기재]',
  '[통신판매업 신고번호 미기재]',
  '[이메일 미기재]'
]) {
  assert(identity.includes(token), `business identity is missing ${token}`);
}

assert(!/@[a-z0-9.-]+\.[a-z]{2,}/i.test(identity), 'business identity contains an email address');
assert(!/\d{3}-\d{2}-\d{5}/.test(identity), 'business identity contains a registration number');
assert(!/\d{2,4}-\d{3,4}-\d{4}/.test(identity), 'business identity contains a phone number');
assert(migration.includes('NOT APPLIED TO PRODUCTION'), 'consent migration must say it is not applied');
assert(migration.includes('draft-2026-11-12'), 'consent migration is missing the draft policy version');
assert(consent.includes('draft-2026-11-12'), 'consent helper is missing the draft policy version');

for (const page of pages) {
  assert(page.includes('법률 검토 전 초안'), 'legal page is missing the draft banner');
  assert(!/\d{3}-\d{2}-\d{5}/.test(page), 'legal page contains a registration number');
}

assert(index.includes('data-business-footer'), 'app is missing the business footer');
assert(index.includes('legal/terms.html'), 'app is missing the terms link');
assert(index.includes('legal/privacy.html'), 'app is missing the privacy link');
assert(index.includes('legal/refund.html'), 'app is missing the refund link');

const subscribe = index.slice(
  index.indexOf('async function handleSubscribe'),
  index.indexOf('async function handleUpgrade')
);
assert(
  subscribe.includes('requestPrePaymentConfirmation') &&
    subscribe.indexOf('requestPrePaymentConfirmation') < subscribe.indexOf('startSubscribe'),
  'card registration must wait for the pre-payment confirmation'
);

if (process.exitCode) process.exit(process.exitCode);
console.log('Legal placeholder checks passed.');
