import { executeFailureRetryCharge } from "./handler.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

Deno.test("a failure retry reuses the order idempotency key", async () => {
  let header: string | null = null;
  const result = await executeFailureRetryCharge({
    orderId: "toss_renew_attempt_1",
    amountKrw: 10000,
    customerKey: "customer_synthetic",
    billingKey: "billing_synthetic",
    authorization: "Basic test",
    fetchImpl: async (_input, init) => {
      header = new Headers(init?.headers).get("Idempotency-Key");
      return new Response(JSON.stringify({
        paymentKey: "pay_synthetic",
        orderId: "toss_renew_attempt_1",
      }), { status: 200 });
    },
  });
  assert(header === "charge_toss_renew_attempt_1", "retry uses the charge idempotency key");
  assert(result.kind === "success", "mocked retry can succeed");
});
