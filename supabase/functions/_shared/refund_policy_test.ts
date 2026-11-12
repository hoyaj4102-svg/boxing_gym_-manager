import { evaluateDraftRefund } from "./refund_policy.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

const paidAt = "2026-11-01T00:00:00.000Z";

function decide(
  overrides: Partial<Parameters<typeof evaluateDraftRefund>[0]>,
) {
  return evaluateDraftRefund({
    paidAt,
    now: "2026-11-03T00:00:00.000Z",
    amountKrw: 10000,
    requestedAmountKrw: 10000,
    reason: "customer_request",
    normallyUsed: false,
    ...overrides,
  });
}

Deno.test("draft refund allows a full unused refund inside seven days", () => {
  const decision = decide({});
  assert(decision.allowed === true, "unused request inside the window is allowed");
  assert(decision.refundAmountKrw === 10000, "the allowed refund is the full amount");
  assert(decision.partial === false, "the allowed refund is not partial");
  assert(
    decide({ now: "2026-11-08T00:00:00.000Z" }).allowed === true,
    "exactly 168 hours is still inside 7 days",
  );
});

Deno.test("draft refund denies partial, normal use, an expired window, and an unconfirmed use", () => {
  assert(
    decide({ requestedAmountKrw: 4000 }).code === "PARTIAL_REFUND_NOT_IN_DRAFT_POLICY",
    "remaining-term partial refunds are denied",
  );
  assert(decide({ normallyUsed: true }).code === "NORMAL_USE_LIMIT", "normal use is limited");
  assert(
    decide({ normallyUsed: null }).code === "NORMAL_USE_UNCONFIRMED",
    "unknown use does not become an automatic refund",
  );
  assert(
    decide({ now: "2026-11-08T00:00:00.001Z" }).code === "REFUND_WINDOW_EXPIRED",
    "one millisecond past seven days is outside the draft window",
  );
});

Deno.test("duplicate and system-error refunds stay full even after seven days", () => {
  for (const reason of ["duplicate_charge", "system_error"]) {
    const decision = decide({
      reason,
      now: "2026-12-01T00:00:00.000Z",
      normallyUsed: true,
    });
    assert(decision.allowed === true, `${reason} stays refundable`);
    assert(decision.refundAmountKrw === 10000, `${reason} is a full refund`);
  }
});
