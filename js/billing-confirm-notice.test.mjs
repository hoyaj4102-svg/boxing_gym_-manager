import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const code = readFileSync(new URL('./billing.js', import.meta.url), 'utf8');
const sandbox = { window: {}, console };
vm.createContext(sandbox);
vm.runInContext(code, sandbox);
const notice = sandbox.window.SweatManagerBilling.billingConfirmNotice;

test('a new charge is a payment success', () => {
  assert.equal(notice({ ok: true, action: 'charge', can_charge: true }), 'payment_success');
});

test('a current entitlement is not announced as a new activation', () => {
  assert.equal(notice({
    ok: true,
    alreadyActive: true,
    entitlementCurrent: true,
    currentPeriodEnd: '2026-12-01T00:00:00.000Z',
  }), 'already_active');
});

test('alreadyActive without a current period is not a success', () => {
  assert.equal(notice({ ok: true, alreadyActive: true }), 'not_activated');
  assert.equal(notice({ ok: true, alreadyActive: true }, { hasPro: false }), 'not_activated');
});

test('a refreshed Pro summary confirms an already active subscription', () => {
  assert.equal(notice({ ok: true, alreadyActive: true }, { hasPro: true }), 'already_active');
});

test('a failed confirm is not a success', () => {
  assert.equal(notice({
    ok: false,
    alreadyActive: false,
    action: 'entitlement_expired',
  }), 'failed');
});

test('an empty confirm result has no notice', () => {
  assert.equal(notice(null), null);
});
