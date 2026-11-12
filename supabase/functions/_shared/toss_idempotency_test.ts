import {
  cancelIdempotencyKey,
  chargeIdempotencyKey,
} from "./toss_idempotency.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("charge and cancel idempotency keys are stable and header-safe", () => {
  assert(
    chargeIdempotencyKey("toss_renew_attempt_1") === "charge_toss_renew_attempt_1",
    "charge key should keep a safe order id",
  );
  assert(
    chargeIdempotencyKey("order/1 2") === "charge_order12",
    "unsafe characters should be removed",
  );
  assert(
    cancelIdempotencyKey("refund_1") === "cancel_refund_1",
    "cancel key should be distinct from the charge key",
  );
});

Deno.test("idempotency key rejects an empty id before any provider call", () => {
  let threw = false;
  try {
    chargeIdempotencyKey("");
  } catch (error) {
    threw = error instanceof Error && error.message === "IDEMPOTENCY_KEY_INVALID";
  }
  assert(threw, "empty order id must not become a provider key");
});
