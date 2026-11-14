import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import test from 'node:test';
import vm from 'node:vm';

const source = readFileSync(new URL('./billing-ops.js', import.meta.url), 'utf8');
const sandbox = { window: {}, URL };
vm.createContext(sandbox);
vm.runInContext(source, sandbox);
const ops = sandbox.window.SweatManagerBillingOps;

test('receipt links stay on Toss https hosts', () => {
  assert.equal(
    ops.safeReceiptUrl('https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic'),
    'https://dashboard.tosspayments.com/receipt/redirection?transactionId=synthetic'
  );
  assert.equal(ops.safeReceiptUrl('http://dashboard.tosspayments.com/receipt'), null);
  assert.equal(ops.safeReceiptUrl('https://example.test/receipt'), null);
  assert.equal(ops.safeReceiptUrl('javascript:alert(1)'), null);
});

test('a customer refund is not submitted until use is explicit', () => {
  assert.equal(ops.refundSubmission({
    reason: 'customer_request',
    amountKrw: 10000,
    normallyUsed: null
  }).code, 'NORMAL_USE_UNCONFIRMED');
  assert.equal(ops.refundSubmission({
    reason: 'duplicate_charge',
    amountKrw: 10000,
    normallyUsed: null
  }).ok, true);
  assert.equal(ops.refundSubmission({
    reason: 'customer_request',
    amountKrw: 10000,
    normallyUsed: false
  }).requestedAmountKrw, 10000);
});

test('refund copy distinguishes an accepted decision from a rejected one', () => {
  const accepted = ops.refundDecisionCopy({
    allowed: true,
    code: 'FULL_REFUND_WITHIN_7_DAYS'
  });
  const rejected = ops.refundDecisionCopy({
    allowed: false,
    decision_code: 'REFUND_WINDOW_EXPIRED'
  });
  const partial = ops.refundDecisionCopy({
    allowed: false,
    decision_code: 'PARTIAL_REFUND_NOT_IN_DRAFT_POLICY'
  });
  assert.equal(accepted.outcome, 'accepted');
  assert.match(accepted.text, /접수/);
  assert.equal(rejected.outcome, 'rejected');
  assert.match(rejected.text, /거절/);
  assert.match(rejected.text, /7일/);
  assert.match(partial.text, /부분 환불/);
  assert.notEqual(accepted.text, rejected.text);
});

test('failure notices do not enable email or sms', () => {
  const notice = ops.failureNotice({
    state: 'past_due',
    card_reregistration_required: true
  });
  assert.equal(notice.email, 'disabled');
  assert.equal(notice.sms, 'disabled');
  assert.equal(notice.cardReregistrationRequired, true);
});
