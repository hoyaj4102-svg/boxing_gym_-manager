import { executeRefund } from "./handler.ts";
import { evaluateDraftRefund } from "../_shared/refund_policy.ts";
import { assessTossTestCall } from "../_shared/toss_test_guard.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

const allowed = evaluateDraftRefund({
  paidAt: "2026-11-01T00:00:00.000Z",
  now: "2026-11-02T00:00:00.000Z",
  amountKrw: 10000,
  requestedAmountKrw: 10000,
  reason: "duplicate_charge",
  normallyUsed: null,
});

Deno.test("a denied draft refund does not call Toss", async () => {
  let calls = 0;
  const result = await executeRefund({
    decision: evaluateDraftRefund({
      paidAt: "2026-11-01T00:00:00.000Z",
      now: "2026-11-02T00:00:00.000Z",
      amountKrw: 10000,
      requestedAmountKrw: 1000,
      reason: "customer_request",
      normallyUsed: false,
    }),
    guard: assessTossTestCall({ mode: "test", secretKey: "test_sk_synthetic" }),
    paymentKey: "pay_synthetic",
    refundRequestId: "refund_synthetic",
    cancelReason: "customer_request",
    authorization: "Basic test",
    fetchImpl: async () => {
      calls += 1;
      return new Response("{}", { status: 200 });
    },
  });
  assert(calls === 0, "partial refund must not reach Toss");
  assert(result.providerCalls === 0, "provider call count stays zero");
  assert(result.status === "denied", "policy denial is recorded");
});

Deno.test("test mode is required even when the draft policy allows a refund", async () => {
  let calls = 0;
  const result = await executeRefund({
    decision: allowed,
    guard: assessTossTestCall({ mode: undefined, secretKey: "test_sk_synthetic" }),
    paymentKey: "pay_synthetic",
    refundRequestId: "refund_synthetic",
    cancelReason: "duplicate_charge",
    authorization: "Basic test",
    fetchImpl: async () => {
      calls += 1;
      return new Response("{}", { status: 200 });
    },
  });
  assert(calls === 0, "default mode must not cancel a payment");
  assert(result.status === "blocked", "the guard blocks the provider");
  assert(result.code === "PROVIDER_MODE_NOT_TEST", "the block reason is the mode");
});

Deno.test("an allowed refund in test mode sends one cancel", async () => {
  let calls = 0;
  const result = await executeRefund({
    decision: allowed,
    guard: assessTossTestCall({ mode: "test", secretKey: "test_sk_synthetic" }),
    paymentKey: "pay_synthetic",
    refundRequestId: "refund_synthetic",
    cancelReason: "duplicate_charge",
    authorization: "Basic test",
    fetchImpl: async () => {
      calls += 1;
      return new Response("{}", { status: 200 });
    },
  });
  assert(calls === 1, "test mode sends the cancel once");
  assert(result.status === "succeeded", "the mocked cancel succeeds");
});
