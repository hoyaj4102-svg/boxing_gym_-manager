import { readFileSync } from "node:fs";

function assert(condition, message) {
  if (!condition) {
    console.error(message);
    process.exitCode = 1;
  }
}

function read(path) {
  return readFileSync(path, "utf8");
}

const copy = read("supabase/p1_23_billing_vault_copy.sql");
const clear = read("supabase/p1_24_billing_vault_clear_plaintext.sql");
const drop = read("supabase/p1_25_billing_vault_drop_plaintext.sql");
const copyRollback = read("supabase/p1_23_billing_vault_copy_rollback.sql");
const clearRollback = read("supabase/p1_24_billing_vault_clear_plaintext_rollback.sql");
const dropRollback = read("supabase/p1_25_billing_vault_drop_plaintext_rollback.sql");
const charge = read("supabase/functions/charge-subscriptions/subscription_charge.ts");

for (const [name, sql] of [
  ["p1_23", copy],
  ["p1_24", clear],
  ["p1_25", drop],
]) {
  assert(
    sql.includes("requires Founder approval before applying to production"),
    `${name} must keep the production approval marker`,
  );
  assert(
    /set search_path = ''/.test(sql),
    `${name} decrypt path must use an empty search_path`,
  );
}

assert(
  copy.includes("private.copy_billing_keys_to_vault"),
  "M1 must copy keys into Vault",
);
assert(
  !/drop column\s+billing_key/i.test(copy),
  "M1 must not drop the plaintext column",
);
assert(
  copy.includes("BILLING_VAULT_COPY_MISMATCH"),
  "M1 must abort when a decrypted secret does not match",
);
assert(
  copy.includes("revoke all on function public.read_gym_billing_vault_credential(uuid) from anon, authenticated"),
  "anon and authenticated must not execute the vault read",
);
assert(
  copy.includes("grant execute on function public.read_gym_billing_vault_credential(uuid) to service_role"),
  "only service_role may execute the vault read",
);
assert(
  copy.includes("revoke all on function private.read_billing_vault_secret(uuid) from anon, authenticated"),
  "anon and authenticated must not execute secret decrypt",
);

assert(
  clear.includes("retire_plaintext = true"),
  "M2 must retire the gyms fallback",
);
assert(
  clear.includes("BILLING_VAULT_PLAINTEXT_NOT_VAULTED"),
  "M2 must refuse a charge source that is not in Vault",
);
assert(
  !/drop column\s+billing_key/i.test(clear),
  "M2 must not drop the plaintext column",
);
assert(
  /non-secret provider reference/i.test(clear),
  "M2 must document which columns stay as references",
);

assert(
  /drop column billing_key/i.test(drop),
  "M3 must drop the plaintext billing key column",
);
assert(
  drop.includes("BILLING_VAULT_PLAINTEXT_REMAINS"),
  "M3 must refuse to drop a column that still has a key",
);
assert(
  !/drop column\s+billing_subscription_id/i.test(drop),
  "M3 must not drop the subscription reference column",
);
assert(
  !/drop column\s+billing_key_ref/i.test(drop),
  "M3 must not drop the attempt reference column",
);
assert(
  !/drop column\s+provider_ref/i.test(drop),
  "M3 must not drop the provider reference column",
);

assert(
  /BILLING_VAULT_ROLLBACK_UNSAFE/.test(copy) &&
    /irreversible/i.test(copyRollback),
  "M1 rollback must say when deleting Vault secrets is unsafe",
);
assert(
  /BILLING_VAULT_ROLLBACK_NEEDS_COLUMN/.test(clear) &&
    /irreversible/i.test(clearRollback),
  "M2 rollback must say it cannot restore a dropped column",
);
assert(
  /BILLING_VAULT_ROLLBACK_INCOMPLETE/.test(drop) &&
    /irreversible/i.test(dropRollback),
  "M3 rollback must say a missing Vault secret cannot be repaired",
);

const vaultCall = charge.indexOf("read_gym_billing_vault_credential");
const plaintextCall = charge.indexOf("read_gym_billing_credential");
assert(
  vaultCall > 0 && plaintextCall > vaultCall,
  "renewal charge must read Vault before the plaintext credential",
);
assert(
  !/console\.(log|error|info|warn)\([^)]*billingKey/.test(charge),
  "renewal charge must not log the billing key",
);

const secretLike = /(sk_live_|toss_sk_|rk_live_|whsec_)/;
for (const sql of [copy, clear, drop, copyRollback, clearRollback, dropRollback]) {
  assert(!secretLike.test(sql), "vault migrations must not contain a live secret");
}

if (process.exitCode) {
  process.exit(process.exitCode);
}

console.log("Billing vault migration checks passed.");
