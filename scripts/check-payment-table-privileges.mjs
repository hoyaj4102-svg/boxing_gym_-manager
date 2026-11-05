import { readFileSync } from "node:fs";

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exitCode = 1;
  }
}

const migration = readFileSync(
  "supabase/p1_16_payment_table_privileges.sql",
  "utf8",
);
const dispatch = readFileSync(
  "supabase/p1_16_subscription_charge_dispatch.sql",
  "utf8",
);

assert(
  migration.includes("requires Founder approval before applying to production"),
  "privilege migration must keep the production approval marker",
);
assert(
  migration.includes("private.enforce_payment_table_write_restrictions()"),
  "privilege migration must apply the restriction",
);
assert(
  !migration.includes("backfill_billing_credentials"),
  "privilege migration must not move existing payment data",
);
assert(
  dispatch.includes("requires Founder approval before applying to production"),
  "dispatch migration must keep the production approval marker",
);
assert(
  dispatch.includes("charge_dispatched_at is null"),
  "dispatch migration must accept only one dispatch",
);
assert(
  !dispatch.includes("api.tosspayments.com"),
  "dispatch migration must not call a payment provider",
);

if (process.exitCode) {
  process.exit(process.exitCode);
}

console.log("Payment table privilege checks passed.");
