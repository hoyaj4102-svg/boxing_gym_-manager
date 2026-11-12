import { cancelIdempotencyKey } from "./toss_idempotency.ts";
import { cancelTossPayment } from "./toss_cancel.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("full cancel sends an idempotency key and omits cancelAmount", async () => {
  const seen: Array<{ url: string; key: string | null; body: Record<string, unknown> }> = [];
  const result = await cancelTossPayment({
    paymentKey: "pay_synthetic",
    cancelReason: "duplicate charge",
    cancelAmountKrw: null,
    idempotencyKey: cancelIdempotencyKey("refund_synthetic"),
    authorization: "Basic test",
    fetchImpl: async (input, init) => {
      seen.push({
        url: String(input),
        key: new Headers(init?.headers).get("Idempotency-Key"),
        body: JSON.parse(String(init?.body || "{}")),
      });
      return new Response("{}", { status: 200 });
    },
  });

  assert(result.kind === "success", "mocked cancel succeeds");
  assert(seen[0].url.endsWith("/v1/payments/pay_synthetic/cancel") === true, "cancel uses the payment cancel path");
  assert(seen[0].key === "cancel_refund_synthetic", "cancel sends Idempotency-Key");
  assert(seen[0].body.cancelAmount === undefined, "a full cancel does not send a partial amount");
  assert(seen[0].body.cancelReason === "duplicate charge", "cancel reason is sent");
});

Deno.test("a partial amount is only present when the caller supplies one", async () => {
  let amount: unknown = "missing";
  await cancelTossPayment({
    paymentKey: "pay_synthetic",
    cancelReason: "partial",
    cancelAmountKrw: 4000,
    idempotencyKey: "cancel_refund_partial",
    authorization: "Basic test",
    fetchImpl: async (_input, init) => {
      amount = JSON.parse(String(init?.body || "{}")).cancelAmount;
      return new Response("{}", { status: 200 });
    },
  });
  assert(amount === 4000, "the HTTP helper can represent a partial amount");
});
