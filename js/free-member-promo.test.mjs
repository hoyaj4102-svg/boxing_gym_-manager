import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const DURING = new Date('2026-12-31T23:59:59+09:00');
const DURING_LAST_MS = new Date('2026-12-31T23:59:59.999+09:00');
const DURING_UTC = new Date('2026-12-31T14:59:59Z');
const AFTER = new Date('2027-01-01T00:00:00+09:00');
const AFTER_UTC = new Date('2026-12-31T15:00:00.000Z');
const PROMO_COPY = '2026년 12월 31일까지 회원 수 제한 없이 무료';
const STANDING_COPY = 'Free 20명 · Pro 월간 구독 (토스)';

const code = readFileSync(new URL('./billing.js', import.meta.url), 'utf8');
const sandbox = { window: {}, console, Intl, URL, Date, Number, Boolean };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const billing = sandbox.window.SweatManagerBilling;

const html = readFileSync(new URL('../index.html', import.meta.url), 'utf8');
const service = readFileSync(new URL('./supabase-service.js', import.meta.url), 'utf8');
const migration = readFileSync(new URL('../supabase/p1_26_free_member_cap_promo.sql', import.meta.url), 'utf8');
const rollback = readFileSync(new URL('../supabase/p1_26_free_member_cap_promo_rollback.sql', import.meta.url), 'utf8');

function t(key, params = {}) {
  if (key === 'planMemberUsage') return `${params.count}/${params.limit}`;
  return key;
}

test('the promo includes 2026-12-31 23:59:59 KST and ends at 2027-01-01 00:00 KST', () => {
  assert.equal(billing.freeMemberPromoActive(DURING), true);
  assert.equal(billing.freeMemberPromoActive(DURING_LAST_MS), true);
  assert.equal(billing.freeMemberPromoActive(DURING_UTC), true);
  assert.equal(DURING.getTime(), DURING_UTC.getTime());
  assert.equal(billing.freeMemberPromoActive(AFTER), false);
  assert.equal(billing.freeMemberPromoActive(AFTER_UTC), false);
  assert.equal(AFTER.getTime(), AFTER_UTC.getTime());
  assert.equal(billing.freeMemberPromoActive(new Date(NaN)), false);
  assert.equal(billing.effectiveFreeMemberLimit(DURING), -1);
  assert.equal(billing.effectiveFreeMemberLimit(DURING_LAST_MS), -1);
  assert.equal(billing.effectiveFreeMemberLimit(AFTER), 20);
  assert.equal(billing.PLANS.free.memberLimit, 20);
  assert.equal(billing.PLANS.free.priceKrw, 0);
  assert.equal(billing.PLANS.pro.memberLimit, -1);
  assert.equal(billing.PLANS.pro.priceKrwMonthly, 10000);
  assert.equal(billing.PLANS.pro.priceKrwYearly, 100000);
});

test('plan copy follows the KST cutoff and the standing Free line stays available', () => {
  assert.equal(billing.billingSubtitleText(t, DURING), 'billingSubtitlePromo');
  assert.equal(billing.billingSubtitleText(t, AFTER), 'billingSubtitle');
  assert.equal((html.match(new RegExp(PROMO_COPY, 'g')) || []).length >= 2, true);
  assert.equal(html.includes(STANDING_COPY), true);
  assert.equal(html.includes('billingSubtitlePromo'), true);
  assert.equal(html.indexOf('./js/billing.js') < html.indexOf('billingSubtitleText'), true);

  const languages = ['ko', 'en', 'es', 'ru', 'mn', 'zh', 'hi', 'fr'];
  for (const language of languages) {
    assert.equal(html.includes(`${language}: {`) || language === 'ko', true);
  }
  assert.equal((html.match(/billingSubtitlePromo:/g) || []).length, 8);
  assert.equal((html.match(/billingSubtitle:/g) || []).length, 8);
});

test('the usage label hides the 20 cap only during the promo', () => {
  const free = {
    hasPro: false,
    memberLimit: 20,
    memberCount: 21
  };
  assert.equal(billing.limitLabel(free, t, DURING), 'planUnlimitedMembers');
  assert.equal(billing.limitLabel(free, t, AFTER), '21/20');
  assert.equal(
    billing.limitLabel({ hasPro: true, memberLimit: 20, memberCount: 30 }, t, AFTER),
    'planUnlimitedMembers',
  );
  assert.equal(
    billing.limitLabel({ hasPro: false, memberLimit: -1, memberCount: 30 }, t, AFTER),
    'planUnlimitedMembers',
  );
});

test('a missing server limit follows the promo and an explicit server limit is kept', () => {
  const duringFallback = billing.normalizeSummary({
    plan_code: 'free',
    has_pro: false,
    member_count: 21
  }, DURING);
  assert.equal(duringFallback.memberLimit, -1);
  assert.equal(duringFallback.canAddMember, true);

  const afterFallback = billing.normalizeSummary({
    plan_code: 'free',
    has_pro: false,
    member_count: 20
  }, AFTER);
  assert.equal(afterFallback.memberLimit, 20);
  assert.equal(afterFallback.canAddMember, false);

  const explicit = billing.normalizeSummary({
    plan_code: 'free',
    has_pro: false,
    member_limit: 20,
    member_count: 20,
    can_add_member: false
  }, DURING);
  assert.equal(explicit.memberLimit, 20);
  assert.equal(explicit.canAddMember, false);
  assert.equal(explicit.planCode, 'free');
});

test('the client pre-check does not block a free gym during the promo', () => {
  const freeBlocked = { hasPro: false, canAddMember: false, memberLimit: 20 };
  assert.equal(billing.clientBlocksMemberInsert(freeBlocked, DURING), false);
  assert.equal(billing.clientBlocksMemberInsert(freeBlocked, AFTER), true);
  assert.equal(billing.clientBlocksMemberInsert({ hasPro: false, canAddMember: true }, AFTER), false);
  assert.equal(
    billing.clientBlocksMemberInsert({ hasPro: true, canAddMember: false }, DURING),
    true,
  );
  assert.equal(service.includes('clientBlocksMemberInsert'), true);
});

test('the migration only changes the effective limit and names the same cutoff', () => {
  assert.equal(migration.includes("timestamptz '2027-01-01 00:00:00+09'"), true);
  assert.equal(migration.includes('return 20;'), true);
  assert.equal(migration.toLowerCase().includes('toss'), false);
  assert.equal(migration.includes('handle_new_user'), false);
  assert.equal(migration.includes('activate_gym_pro'), false);
  assert.equal(migration.toLowerCase().includes('update public.gyms'), false);
  assert.equal(rollback.includes('return 20;'), true);
  assert.equal(rollback.includes('drop function if exists public.member_limit_now()'), true);
  assert.equal(rollback.toLowerCase().includes('toss'), false);
  assert.equal(rollback.toLowerCase().includes('update public.gyms'), false);
});
