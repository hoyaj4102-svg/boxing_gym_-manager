import { createOrderChargeGuard } from "../_shared/billing_order_reconciliation.ts";
import { settleInitialBillingCharge } from "./initial_billing_charge.ts";

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
    );
  }
}

const donePayment = {
  paymentKey: "payment_initial",
  orderId: "toss_bill_attempt_1",
  status: "DONE",
  totalAmount: 10000,
};

function charge(fetchImpl: typeof fetch, lookupBeforePost = false) {
  return settleInitialBillingCharge({
    orderId: "toss_bill_attempt_1",
    amountKrw: 10000,
    billingKey: "billing_key_1",
    authorization: "Basic test",
    customerKey: "customer_1",
    orderName: "re;member Pro 월간 구독",
    idempotencyKey: "charge_toss_bill_attempt_1",
    tossSecret: "test_secret",
    fetchImpl,
    lookupBeforePost,
  });
}

Deno.test("the first charge records a DONE billing response without a lookup", async () => {
  const methods: string[] = [];
  const result = await charge(async (_input, init) => {
    methods.push(String(init?.method || "GET"));
    return new Response(JSON.stringify(donePayment), { status: 200 });
  });
  assertEquals(methods, ["POST"], "a clear DONE response is not looked up");
  assertEquals(result.settlement.kind, "paid", "DONE is paid");
});

Deno.test("the first charge records an explicit card failure", async () => {
  const methods: string[] = [];
  const result = await charge(async (_input, init) => {
    methods.push(String(init?.method || "GET"));
    return new Response(
      JSON.stringify({ code: "REJECT_CARD_COMPANY", message: "declined" }),
      { status: 400 },
    );
  });
  assertEquals(methods, ["POST"], "a clear rejection is not looked up");
  assertEquals(result.settlement.kind, "failed", "the rejection is kept");
});

Deno.test("the first charge looks up a timeout and records DONE", async () => {
  const methods: string[] = [];
  const result = await charge(async (_input, init) => {
    const method = String(init?.method || "GET");
    methods.push(method);
    if (method === "POST") throw new TypeError("timeout");
    return new Response(JSON.stringify(donePayment), { status: 200 });
  });
  assertEquals(methods, ["POST", "GET"], "timeout is followed by one lookup");
  assertEquals(result.settlement.kind, "paid", "lookup DONE is paid");
  assertEquals(result.providerPosts, 1, "the approval was posted once");
});

Deno.test("the first charge does not post again when the order is missing", async () => {
  const methods: string[] = [];
  const result = await charge(async (_input, init) => {
    methods.push(String(init?.method || "GET"));
    if (String(init?.method || "GET") === "POST") throw new TypeError("timeout");
    return new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 });
  });
  assertEquals(methods, ["POST", "GET"], "not-found does not create a second order");
  assertEquals(result.settlement.kind, "retry_same_order", "the same order can be retried");
});

Deno.test("a paymentKey without status is looked up and is not paid when still unclear", async () => {
  const methods: string[] = [];
  const result = await charge(async (_input, init) => {
    methods.push(String(init?.method || "GET"));
    return new Response(JSON.stringify({
      paymentKey: "payment_initial",
      orderId: "toss_bill_attempt_1",
      totalAmount: 10000,
    }), { status: 200 });
  });
  assertEquals(methods, ["POST", "GET"], "missing status is re-queried once");
  assertEquals(result.providerPosts, 1, "the unclear approval is not posted twice");
  assertEquals(result.settlement.kind, "needs_review", "an unclear lookup waits for review");
});

Deno.test("a same-order retry looks up before posting", async () => {
  const guard = createOrderChargeGuard();
  const methods: string[] = [];
  let posts = 0;
  const fetchImpl: typeof fetch = async (_input, init) => {
    const method = String(init?.method || "GET");
    methods.push(method);
    if (method === "POST") {
      posts += 1;
      return new Response(JSON.stringify(donePayment), { status: 200 });
    }
    if (posts > 0) return new Response(JSON.stringify(donePayment), { status: 200 });
    return new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 });
  };
  const first = await settleInitialBillingCharge({
    orderId: "toss_bill_attempt_1",
    amountKrw: 10000,
    billingKey: "billing_key_1",
    authorization: "Basic test",
    customerKey: "customer_1",
    orderName: "re;member Pro 월간 구독",
    idempotencyKey: "charge_toss_bill_attempt_1",
    tossSecret: "test_secret",
    fetchImpl,
    guard,
    lookupBeforePost: true,
  });
  const second = await settleInitialBillingCharge({
    orderId: "toss_bill_attempt_1",
    amountKrw: 10000,
    billingKey: "billing_key_1",
    authorization: "Basic test",
    customerKey: "customer_1",
    orderName: "re;member Pro 월간 구독",
    idempotencyKey: "charge_toss_bill_attempt_1",
    tossSecret: "test_secret",
    fetchImpl,
    guard,
    lookupBeforePost: true,
  });
  assertEquals(methods, ["GET", "POST", "GET"], "the replay does not post again");
  assertEquals(first.providerPosts, 1, "the first retry posts once");
  assertEquals(second.providerPosts, 0, "the second retry only looks up");
  assertEquals(second.settlement.kind, "paid", "the replay sees the recorded payment");
});
