import { interpretConsentGate } from "./consent_gate.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("a missing consent function keeps the previous charge path", () => {
  assert(
    interpretConsentGate({
      data: null,
      error: { code: "PGRST202", message: "Could not find the function" },
    }) === "skip_missing",
    "an unapplied migration must not be treated as a denial",
  );
  assert(
    interpretConsentGate({ data: { ok: true }, error: null }) === "skip_missing",
    "an old payload without allowed does not change the charge",
  );
});

Deno.test("an explicit consent denial blocks the provider call", () => {
  assert(
    interpretConsentGate({
      data: { allowed: false, code: "PRICE_NOT_AUTHORIZED" },
      error: null,
    }) === "deny",
    "allowed false blocks the charge",
  );
  assert(
    interpretConsentGate({ data: { allowed: true }, error: null }) === "allow",
    "allowed true passes the gate",
  );
  assert(
    interpretConsentGate({
      data: null,
      error: { code: "57014", message: "canceling statement due to statement timeout" },
    }) === "deny",
    "a real database error fails closed",
  );
});
