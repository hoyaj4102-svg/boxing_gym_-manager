import {
  executeFailureRetryCharge,
  failureRetryAttemptUpdate,
} from "./handler.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const doneBody = {
  paymentKey: "pay_synthetic",
  orderId: "toss_renew_attempt_1",
  status: "DONE",
  totalAmount: 10000,
};

Deno.test("a failure retry reuses the order idempotency key and records DONE", async () => {
  let header: string | null = null;
  const methods: string[] = [];
  const result = await executeFailureRetryCharge({
    orderId: "toss_renew_attempt_1",
    amountKrw: 10000,
    customerKey: "customer_synthetic",
    billingKey: "billing_synthetic",
    authorization: "Basic test",
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      const method = String(init?.method || "GET");
      methods.push(method);
      if (method === "GET") {
        return new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 });
      }
      header = new Headers(init?.headers).get("Idempotency-Key");
      return new Response(JSON.stringify(doneBody), { status: 200 });
    },
  });
  assertEquals(methods, ["GET", "POST"], "retry looks up before it posts");
  assert(header === "charge_toss_renew_attempt_1", "retry uses the charge idempotency key");
  assertEquals(result.settlement.kind, "paid", "a DONE retry is recorded as paid");
  assertEquals(result.providerPosts, 1, "the retry posts once");
  assertEquals(
    failureRetryAttemptUpdate(result.settlement).payment_key,
    "pay_synthetic",
    "the payment key is kept",
  );
});

Deno.test("a failure retry does not post when the order is already DONE", async () => {
  const methods: string[] = [];
  const result = await executeFailureRetryCharge({
    orderId: "toss_renew_attempt_1",
    amountKrw: 10000,
    customerKey: "customer_synthetic",
    billingKey: "billing_synthetic",
    authorization: "Basic test",
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      methods.push(String(init?.method || "GET"));
      return new Response(JSON.stringify(doneBody), { status: 200 });
    },
  });
  assertEquals(methods, ["GET"], "an existing DONE payment is not charged again");
  assertEquals(result.providerPosts, 0, "no approval is posted");
  assertEquals(result.settlement.kind, "paid", "the lookup is recorded");
});

Deno.test("a failure retry without status stays in review", async () => {
  const methods: string[] = [];
  const result = await executeFailureRetryCharge({
    orderId: "toss_renew_attempt_1",
    amountKrw: 10000,
    customerKey: "customer_synthetic",
    billingKey: "billing_synthetic",
    authorization: "Basic test",
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      methods.push(String(init?.method || "GET"));
      return new Response(JSON.stringify({
        paymentKey: "pay_synthetic",
        orderId: "toss_renew_attempt_1",
        totalAmount: 10000,
      }), { status: 200 });
    },
  });
  assertEquals(methods, ["GET"], "missing status does not become a charge");
  assertEquals(result.settlement.kind, "needs_review", "missing status stays in review");
  assertEquals(
    failureRetryAttemptUpdate(result.settlement).recovery_status,
    "pending",
    "the attempt waits for review",
  );
});
