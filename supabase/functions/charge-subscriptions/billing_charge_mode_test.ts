import { isLiveBillingCharge } from "./billing_charge_mode.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("billing charge stays off unless the mode is exactly live", () => {
  assert(isLiveBillingCharge("live") === true, "live mode is the only charge mode");
  for (const mode of [undefined, null, "", "dry-run", "dry_run", "LIVE", "live "]) {
    assert(
      isLiveBillingCharge(mode) === false,
      `mode ${JSON.stringify(mode)} must not charge`,
    );
  }
});
