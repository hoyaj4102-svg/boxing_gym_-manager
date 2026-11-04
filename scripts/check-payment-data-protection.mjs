import { readFileSync } from "node:fs";

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exitCode = 1;
  }
}

function grantColumns(sql, table) {
  const match = sql.match(
    new RegExp(
      `grant select \\(([\\s\\S]*?)\\) on table ${table} to anon, authenticated`,
      "i",
    ),
  );
  return match ? match[1] : "";
}

const migration = readFileSync(
  "supabase/p0_payment_data_protection.sql",
  "utf8",
);
const confirmSource = readFileSync(
  "supabase/functions/confirm-billing-auth/index.ts",
  "utf8",
);
const chargeSource = readFileSync(
  "supabase/functions/charge-subscriptions/subscription_charge.ts",
  "utf8",
);
const workflow = readFileSync(
  ".github/workflows/charge-subscriptions.yml",
  "utf8",
);

assert(
  migration.includes(
    "requires Founder approval before applying to production",
  ),
  "migration must keep the production approval marker",
);
assert(
  migration.includes("create schema if not exists private"),
  "private schema must be created",
);
assert(
  migration.includes("revoke all on schema private from anon, authenticated"),
  "private schema must be closed to owner roles",
);
assert(
  !/grant\s+(usage|all)[\s\S]*?on schema private to (anon|authenticated|public)\b/i
    .test(migration),
  "private schema must not be granted to owner roles",
);
assert(
  migration.includes(
    "grant execute on function public.read_gym_billing_credential(uuid) to service_role",
  ),
  "credential read must be limited to the service role",
);
assert(
  migration.includes(
    "revoke all on function public.read_gym_billing_credential(uuid) from anon, authenticated",
  ),
  "owner roles must not execute credential reads",
);

const gymGrant = grantColumns(migration, "public\\.gyms");
const attemptGrant = grantColumns(migration, "public\\.payment_attempts");
const checkoutGrant = grantColumns(migration, "public\\.checkout_sessions");

assert(gymGrant.length > 0, "gym owner select grant missing");
assert(
  !gymGrant.includes("billing_subscription_id"),
  "owner gym select must not include the credential column",
);
assert(attemptGrant.length > 0, "attempt owner select grant missing");
assert(
  !attemptGrant.includes("billing_key_ref"),
  "owner attempt select must not include the credential column",
);
assert(
  !attemptGrant.includes("provider_response"),
  "owner attempt select must not include stored provider payloads",
);
assert(checkoutGrant.length > 0, "checkout owner select grant missing");
assert(
  !/\braw\b/.test(checkoutGrant),
  "owner checkout select must not include stored payloads",
);

assert(
  !confirmSource.includes("billing_key_ref:"),
  "billing confirmation must not persist the credential on an owner-readable attempt",
);
assert(
  confirmSource.includes("upsert_gym_billing_credential"),
  "billing confirmation must store the credential through the private write",
);
assert(
  confirmSource.includes("sanitizeProviderPayload"),
  "billing confirmation must sanitize provider payloads",
);
assert(
  !/raw:\s*\{/.test(confirmSource),
  "billing confirmation payload writes must go through the sanitizer",
);

assert(
  chargeSource.includes("resolveBillingCredential"),
  "renewal charge must resolve the credential before charging",
);
assert(
  chargeSource.includes("read_gym_billing_credential"),
  "renewal charge must read the private credential",
);
assert(
  /raw:\s*sanitizeProviderPayload\(/.test(chargeSource),
  "renewal payload writes must go through the sanitizer",
);
assert(
  chargeSource.includes("amountKrw"),
  "renewal charge must keep using the claimed amount",
);

assert(
  workflow.startsWith("name: Charge Toss Subscriptions\n"),
  "recurring charge workflow must stay unchanged",
);
assert(
  !workflow.includes("p0_payment_data_protection"),
  "recurring charge workflow must not be wired to this change",
);

if (process.exitCode) {
  process.exit(process.exitCode);
}

console.log("Payment data protection checks passed.");
