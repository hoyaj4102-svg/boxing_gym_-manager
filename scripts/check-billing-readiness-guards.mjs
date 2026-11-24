import { readFileSync, readdirSync } from 'node:fs';

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exitCode = 1;
  }
}

const cancelIndex = readFileSync('supabase/functions/cancel-payment/index.ts', 'utf8');
const receiptIndex = readFileSync('supabase/functions/payment-receipt/index.ts', 'utf8');
const retryIndex = readFileSync('supabase/functions/retry-failed-payments/index.ts', 'utf8');
const chargeIndex = readFileSync('supabase/functions/charge-subscriptions/index.ts', 'utf8');
const workflows = readdirSync('.github/workflows').filter((name) => name.endsWith('.yml'));

assert(
  cancelIndex.indexOf('assessTossTestCall') < cancelIndex.indexOf('executeRefund('),
  'cancel must assess test mode before executing a refund'
);
assert(
  receiptIndex.indexOf('assessTossTestCall') < receiptIndex.indexOf('executeReceiptLookup('),
  'receipt lookup must assess test mode before querying Toss'
);
assert(
  receiptIndex.includes('resolve_attempt_payment_key'),
  'receipt lookup must resolve the dedicated payment key'
);
assert(!receiptIndex.includes('provider_response'), 'receipt lookup must not read provider_response');
assert(!cancelIndex.includes('provider_response'), 'cancel must not read provider_response');
assert(
  retryIndex.indexOf('if (decision !== "proceed")') < retryIndex.indexOf('getAdminClient()'),
  'failure retry must return before opening a database client unless test mode passes'
);
assert(!/^\s*schedule\s*:/m.test(retryIndex), 'failure retry must not declare a schedule');
assert(chargeIndex.includes('isLiveBillingCharge'), 'recurring charge must keep its live-mode gate');
assert(!chargeIndex.includes("BILLING_CHARGE_MODE = 'live'"), 'charge mode must not be switched to live');
assert(!chargeIndex.includes('BILLING_CHARGE_MODE = "live"'), 'charge mode must not be switched to live');

for (const name of workflows) {
  const workflow = readFileSync(`.github/workflows/${name}`, 'utf8');
  assert(!/^\s*schedule\s*:/m.test(workflow), `${name} must not add a schedule`);
  assert(!/^\s*cron\s*:/m.test(workflow), `${name} must not add a cron`);
}

const deniedFiles = [
  'supabase/functions/cancel-payment/index.ts',
  'supabase/functions/retry-failed-payments/index.ts',
  'supabase/functions/_shared/toss_cancel.ts',
  'js/billing-ops.js'
];
for (const file of deniedFiles) {
  const source = readFileSync(file, 'utf8');
  assert(!/live_sk_/.test(source), `${file} must not contain a live secret prefix value`);
  assert(!/sendgrid|resend\.com|twilio|nodemailer/i.test(source), `${file} must not add an email or sms sender`);
}

if (process.exitCode) process.exit(process.exitCode);
console.log('Billing readiness guard checks passed.');
