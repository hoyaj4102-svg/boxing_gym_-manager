import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./billing-consent.js', import.meta.url), 'utf8');
const sql = readFileSync(new URL('../supabase/p1_20_billing_consent.sql', import.meta.url), 'utf8');
const sandbox = { window: {} };
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const consent = sandbox.window.SweatManagerBillingConsent;

test('the 30-day window matches the stated 2025-06-01 example', () => {
  const conversion = '2025-06-01T00:00:00+09:00';
  assert.equal(consent.consentInWindow('2025-05-02T00:00:00+09:00', conversion), true);
  assert.equal(consent.consentInWindow('2025-05-31T23:59:00+09:00', conversion), true);
  assert.equal(consent.consentInWindow('2025-05-01T23:59:00+09:00', conversion), false);
  assert.equal(consent.consentInWindow('2025-06-01T00:00:00+09:00', conversion), false);
  assert.equal(consent.windowState('2025-05-02T00:00:00+09:00', conversion).code, 'WINDOW_OPEN');
  assert.equal(consent.windowState('2025-04-01T00:00:00+09:00', conversion).code, 'WINDOW_NOT_OPEN');
  assert.equal(consent.windowState('2025-06-01T00:00:00+09:00', conversion).code, 'WINDOW_CLOSED');
});

test('pre-payment disclosure states price, cycle, renewal, and cancellation', () => {
  const disclosure = consent.buildPrePaymentDisclosure('2026-11-12T08:00:00.000Z');
  assert.equal(disclosure.draft, true);
  assert.equal(disclosure.policyVersion, 'draft-2026-11-12');
  assert.equal(disclosure.amountKrw, 10000);
  assert.equal(disclosure.billingCycle, 'monthly');
  assert.equal(disclosure.autoRenew, true);
  assert.equal(disclosure.firstChargeAt, '2026-11-12T08:00:00.000Z');
  assert.equal(disclosure.nextChargeAt, '2026-12-12T08:00:00.000Z');
  assert.equal(disclosure.nextChargeEstimate, true);
  assert.match(disclosure.cancellationMethod, /해지/);
  assert.match(sql, new RegExp(disclosure.cancellationMethod.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.match(sql, /draft-2026-11-12/);
});

test('continue stays blocked until every required consent is checked', () => {
  assert.equal(
    JSON.stringify(consent.prePaymentContinueState({ paymentChecked: false })),
    JSON.stringify({ ok: false, missing: ['pre_payment'] })
  );
  assert.equal(
    JSON.stringify(consent.prePaymentContinueState({
      paymentChecked: true,
      trialRequired: true,
      trialChecked: false,
      priceRequired: true,
      priceChecked: false
    })),
    JSON.stringify({ ok: false, missing: ['trial_to_paid', 'price_increase'] })
  );
  assert.equal(consent.prePaymentContinueState({
    paymentChecked: true,
    trialRequired: true,
    trialChecked: true,
    priceRequired: false
  }).ok, true);
});

test('trial and price prompts follow the readiness payload', () => {
  const readiness = {
    trial: {
      consent_required_for_conversion: true,
      window_open: true,
      consent_status: 'missing'
    },
    price_schedules: [
      { window_open: false, consent_status: 'missing' },
      { window_open: true, consent_status: 'granted' }
    ]
  };
  assert.equal(consent.trialConsentRequired(readiness), true);
  assert.equal(consent.priceConsentRequired(readiness), false);
  readiness.trial.consent_status = 'granted';
  readiness.price_schedules[1].consent_status = 'declined';
  assert.equal(consent.trialConsentRequired(readiness), false);
  assert.equal(consent.priceConsentRequired(readiness), true);
});
