import {
  chargeAndSettleRecurringBilling,
  classifyOrderLookup,
  createOrderChargeGuard,
  lookupTossPaymentByOrderId,
  ORDER_NOT_FOUND_RETRY_CODE,
  planAttemptWrite,
  reconcilePendingBillingOrder,
} from "./billing_order_reconciliation.ts";
import { REDACTED, sanitizeProviderPayload } from "./sanitize_provider_payload.ts";
import { processClaimedSubscriptionCharge } from "../charge-subscriptions/subscription_charge.ts";
import { processReconciliationAttempt } from "../reconcile-auto-renewal-payments/reconciliation.ts";

function assert(condition: unknown, message: string) {
  if (!condition) throw new Error(message);
}

function assertEquals(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(
      `${message}: expected ${JSON.stringify(expected)}, got ${
        JSON.stringify(actual)
      }`,
    );
  }
}

const ORDER_ID = "toss_renew_attempt_1";

function donePayment(paymentKey = "payment_done") {
  return {
    paymentKey,
    orderId: ORDER_ID,
    status: "DONE",
    totalAmount: 10000,
  };
}

function chargeInput(
  fetchImpl: typeof fetch,
  guard = createOrderChargeGuard(),
) {
  return {
    orderId: ORDER_ID,
    amountKrw: 10000,
    billingKey: "billing_key_1",
    authorization: "Basic test",
    customerKey: "customer_1",
    orderName: "re;member Pro 월간 자동결제",
    idempotencyKey: "charge_toss_renew_attempt_1",
    tossSecret: "test_secret",
    fetchImpl,
    guard,
  };
}

function scriptedFetch(responses: Array<(method: string) => Response | Promise<Response>>) {
  const methods: string[] = [];
  const fetchImpl: typeof fetch = async (_input, init) => {
    const method = String(init?.method || "GET");
    methods.push(method);
    const next = responses.shift();
    if (!next) throw new Error(`unexpected ${method}`);
    return await next(method);
  };
  return { methods, fetchImpl };
}

Deno.test("paymentKey without status is not paid until the order lookup is DONE", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () =>
      new Response(JSON.stringify({
        paymentKey: "payment_missing_status",
        orderId: ORDER_ID,
        totalAmount: 10000,
      }), { status: 200 }),
    () =>
      new Response(JSON.stringify({
        paymentKey: "payment_missing_status",
        orderId: ORDER_ID,
        totalAmount: 10000,
      }), { status: 200 }),
  ]);
  const unclear = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));
  assertEquals(methods, ["POST", "GET"], "missing status is re-queried and not posted again");
  assertEquals(unclear.settlement.kind, "needs_review", "an unclear lookup is not paid");

  const confirmed = scriptedFetch([
    () =>
      new Response(JSON.stringify({
        paymentKey: "payment_missing_status",
        orderId: ORDER_ID,
        totalAmount: 10000,
      }), { status: 200 }),
    () => new Response(JSON.stringify(donePayment("payment_missing_status")), { status: 200 }),
  ]);
  const paid = await chargeAndSettleRecurringBilling(chargeInput(confirmed.fetchImpl));
  assertEquals(confirmed.methods, ["POST", "GET"], "a missing status is confirmed by lookup");
  assertEquals(paid.settlement.kind, "paid", "lookup DONE is paid");
});

Deno.test("a released retry looks the order up before posting again", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () => new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 }),
    (method) => {
      assertEquals(method, "POST", "not-found is the only reason to post");
      return new Response(JSON.stringify(donePayment("payment_retry")), { status: 200 });
    },
  ]);
  const result = await chargeAndSettleRecurringBilling({
    ...chargeInput(fetchImpl),
    lookupBeforePost: true,
  });
  assertEquals(methods, ["GET", "POST"], "the retry queries before it posts");
  assertEquals(result.providerPosts, 1, "one post uses the same order");
  assertEquals(result.settlement.kind, "paid", "the retried approval is paid");
});

Deno.test("a released retry does not post when the lookup is already DONE", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () => new Response(JSON.stringify(donePayment("payment_already")), { status: 200 }),
  ]);
  const result = await chargeAndSettleRecurringBilling({
    ...chargeInput(fetchImpl),
    lookupBeforePost: true,
  });
  assertEquals(methods, ["GET"], "DONE lookup blocks another charge");
  assertEquals(result.providerPosts, 0, "no second approval is posted");
  assertEquals(result.settlement.kind, "paid", "the existing payment is recorded");
});

Deno.test("DONE billing response is paid by orderId without a lookup or webhook", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    (method) => {
      assertEquals(method, "POST", "the approval itself is the success signal");
      return new Response(JSON.stringify(donePayment()), { status: 200 });
    },
  ]);

  const result = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));

  assertEquals(methods, ["POST"], "DONE response must not query or charge again");
  assertEquals(result.providerPosts, 1, "one approval is recorded");
  assertEquals(result.settlement.kind, "paid", "DONE is paid");
  assertEquals(
    result.settlement.kind === "paid" ? result.settlement.paymentKey : null,
    "payment_done",
    "payment key comes from the billing response",
  );
  assertEquals(
    result.settlement.kind === "paid" ? result.settlement.source : null,
    "billing_response",
    "the billing response is the source of truth",
  );
});

Deno.test("explicit card failure is recorded and is not looked up", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () =>
      new Response(
        JSON.stringify({ code: "REJECT_CARD_COMPANY", message: "declined" }),
        { status: 400 },
      ),
  ]);

  const result = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));

  assertEquals(methods, ["POST"], "a clear rejection must not look up or retry");
  assertEquals(result.settlement.kind, "failed", "rejection stays a failure");
  assertEquals(
    result.settlement.kind === "failed" ? result.settlement.code : null,
    "REJECT_CARD_COMPANY",
    "the Toss rejection code is kept",
  );
});

Deno.test("timeout then order lookup DONE is recorded as paid once", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () => {
      throw new TypeError("network timeout after approval");
    },
    (method) => {
      assertEquals(method, "GET", "timeout recovery uses the order lookup");
      return new Response(JSON.stringify(donePayment("payment_after_timeout")), {
        status: 200,
      });
    },
  ]);

  const result = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));

  assertEquals(methods, ["POST", "GET"], "timeout performs one lookup and no second charge");
  assertEquals(result.providerPosts, 1, "the timed-out approval counts as one post");
  assertEquals(result.settlement.kind, "paid", "lookup DONE is paid");
  assertEquals(
    result.settlement.kind === "paid" ? result.settlement.source : null,
    "order_lookup",
    "the order lookup settles the ambiguous approval",
  );
});

Deno.test("a non-DONE lookup is pending review and is not charged again", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () => {
      throw new TypeError("timeout");
    },
    () =>
      new Response(
        JSON.stringify({
          paymentKey: "payment_in_progress",
          orderId: ORDER_ID,
          status: "IN_PROGRESS",
          totalAmount: 10000,
        }),
        { status: 200 },
      ),
  ]);

  const result = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));

  assertEquals(methods, ["POST", "GET"], "an in-progress payment is not charged again");
  assertEquals(result.settlement.kind, "needs_review", "other states wait for review");
  assertEquals(
    result.settlement.kind === "needs_review" ? result.settlement.code : null,
    "TOSS_PAYMENT_VALIDATION_FAILED",
    "a non-DONE payment is not recorded as paid",
  );
});

Deno.test("timeout then order lookup not-found can retry only the same orderId", async () => {
  const { methods, fetchImpl } = scriptedFetch([
    () => {
      throw new TypeError("network timeout before a response");
    },
    () => new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 }),
  ]);

  const result = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl));

  assertEquals(methods, ["POST", "GET"], "not-found must not post a second order");
  assertEquals(result.settlement.kind, "retry_same_order", "not-found is retryable");
  assertEquals(
    result.settlement.kind === "retry_same_order" ? result.settlement.code : null,
    ORDER_NOT_FOUND_RETRY_CODE,
    "retry stays tied to the original order",
  );
});

Deno.test("replaying the same orderId does not charge it twice", async () => {
  const guard = createOrderChargeGuard();
  let posts = 0;
  const fetchImpl: typeof fetch = async (_input, init) => {
    const method = String(init?.method || "GET");
    if (method === "POST") {
      posts += 1;
      throw new TypeError("timeout");
    }
    return new Response(JSON.stringify(donePayment("payment_replay")), { status: 200 });
  };

  const first = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl, guard));
  const second = await chargeAndSettleRecurringBilling(chargeInput(fetchImpl, guard));

  assertEquals(posts, 1, "the second call must not POST the same orderId");
  assertEquals(first.providerPosts, 1, "the first ambiguous approval posts once");
  assertEquals(second.providerPosts, 0, "replay only looks the order up");
  assertEquals(first.settlement.kind, "paid", "first lookup settles DONE");
  assertEquals(second.settlement.kind, "paid", "replay sees the same DONE payment");
  assertEquals(
    second.settlement.kind === "paid" ? second.settlement.paymentKey : null,
    "payment_replay",
    "replay keeps the original payment key",
  );
});

Deno.test("a recorded payment is not downgraded or charged again", () => {
  const current = {
    orderId: ORDER_ID,
    status: "completed",
    paymentKey: "payment_replay",
  };
  const samePayment = planAttemptWrite(current, {
    kind: "paid",
    paymentKey: "payment_replay",
    payload: donePayment("payment_replay"),
    source: "order_lookup",
  });
  const missingLater = planAttemptWrite(current, {
    kind: "retry_same_order",
    code: ORDER_NOT_FOUND_RETRY_CODE,
    message: "missing",
    payload: null,
    priorCode: null,
  });

  assertEquals(samePayment.apply, false, "the same DONE payment is already recorded");
  assertEquals(samePayment.chargeAgain, false, "replay must not charge");
  assertEquals(missingLater.chargeAgain, false, "a later gap must not charge a paid order");
  assertEquals(missingLater.clearDispatch, false, "a paid order keeps its dispatch lock");
  assertEquals(missingLater.paymentKey, "payment_replay", "the stored payment key stays");
});

Deno.test("reconciliation pass settles pending orders by lookup and never charges", async () => {
  const calls: string[] = [];
  const fetchImpl: typeof fetch = async (input, init) => {
    calls.push(String(init?.method || "GET"));
    if (String(init?.method || "GET") === "POST") {
      throw new Error("reconciliation must not charge");
    }
    const url = String(input);
    assert(url.includes(`/payments/orders/${ORDER_ID}`), "lookup uses the same orderId");
    return new Response(JSON.stringify(donePayment("payment_reconciled")), { status: 200 });
  };

  const first = await reconcilePendingBillingOrder({
    orderId: ORDER_ID,
    amountKrw: 10000,
    lookupOrder: async () => {
      const response = await fetchImpl(
        `https://api.tosspayments.com/v1/payments/orders/${ORDER_ID}`,
        { method: "GET" },
      );
      return {
        kind: "found" as const,
        payment: await response.json(),
      };
    },
  });
  const second = await reconcilePendingBillingOrder({
    orderId: ORDER_ID,
    amountKrw: 10000,
    lookupOrder: async () => ({
      kind: "not_found" as const,
      status: 404,
      payload: { code: "NOT_FOUND_PAYMENT" },
    }),
  });

  assertEquals(calls, ["GET"], "the pass only looks up");
  assertEquals(first.providerPosts, 0, "DONE lookup does not charge");
  assertEquals(first.settlement.kind, "paid", "pending DONE lookup is paid");
  assertEquals(second.providerPosts, 0, "not-found lookup does not charge");
  assertEquals(second.settlement.kind, "retry_same_order", "not-found stays on the same order");
});

function claimAdmin() {
  const updates: Array<{ table: string; values: Record<string, unknown> }> = [];
  const inserts: Array<{ table: string }> = [];
  const rpcCalls: string[] = [];
  return {
    updates,
    inserts,
    rpcCalls,
    admin: {
      from(table: string) {
        return {
          update(values: Record<string, unknown>) {
            return {
              async eq() {
                updates.push({ table, values });
                return { error: null };
              },
            };
          },
          async insert() {
            inserts.push({ table });
            return { error: null };
          },
        };
      },
      async rpc(name: string) {
        rpcCalls.push(name);
        if (name === "claim_subscription_charge_dispatch") {
          return { data: true, error: null };
        }
        return { data: { ok: true }, error: null };
      },
    },
  };
}

Deno.test("claimed renewal stores lookup DONE and does not mark the gym past due", async () => {
  const { admin, updates, inserts, rpcCalls } = claimAdmin();
  const methods: string[] = [];

  const result = await processClaimedSubscriptionCharge(
    admin,
    {
      payment_attempt_id: "attempt_1",
      gym_id: "gym_1",
      user_id: "user_1",
      order_id: ORDER_ID,
      customer_key: "customer_1",
      billing_key_ref: "billing_key_1",
      target_period_start: "2026-01-01T00:00:00.000Z",
      target_period_end: "2026-02-01T00:00:00.000Z",
      amount_krw: 10000,
    },
    {
      tossSecret: "test_secret",
      now: () => new Date("2026-01-01T00:10:00.000Z"),
      fetchImpl: async (_input, init) => {
        const method = String(init?.method || "GET");
        methods.push(method);
        if (method === "POST") throw new TypeError("timeout");
        return new Response(JSON.stringify(donePayment("payment_after_timeout")), {
          status: 200,
        });
      },
    },
  );

  assertEquals(methods, ["POST", "GET"], "renewal lookup does not post twice");
  assertEquals(result.ok, true, "lookup DONE completes the renewal");
  assertEquals(result.orderId, ORDER_ID, "the settled order is the charged order");
  assertEquals(inserts.length, 1, "one checkout row is recorded for the order");
  assertEquals(
    updates.find((update) => update.table === "payment_attempts")?.values.payment_key,
    "payment_after_timeout",
    "the lookup payment key is stored",
  );
  assertEquals(
    updates.filter((update) => update.table === "gyms").length,
    0,
    "a recovered DONE payment is not a card failure",
  );
  assert(
    rpcCalls.includes("activate_payment_attempt"),
    "lookup DONE activates the same attempt",
  );
});

Deno.test("claimed renewal not-found keeps the same order and does not mark past due", async () => {
  const { admin, updates, inserts } = claimAdmin();
  const methods: string[] = [];

  const result = await processClaimedSubscriptionCharge(
    admin,
    {
      payment_attempt_id: "attempt_1",
      gym_id: "gym_1",
      user_id: "user_1",
      order_id: ORDER_ID,
      customer_key: "customer_1",
      billing_key_ref: "billing_key_1",
      target_period_start: "2026-01-01T00:00:00.000Z",
      target_period_end: "2026-02-01T00:00:00.000Z",
      amount_krw: 10000,
    },
    {
      tossSecret: "test_secret",
      now: () => new Date("2026-01-01T00:10:00.000Z"),
      fetchImpl: async (_input, init) => {
        methods.push(String(init?.method || "GET"));
        if (String(init?.method || "GET") === "POST") {
          throw new TypeError("timeout");
        }
        return new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), {
          status: 404,
        });
      },
    },
  );

  const attempt = updates.find((update) => update.table === "payment_attempts");
  assertEquals(methods, ["POST", "GET"], "not-found does not create a second charge");
  assertEquals(result.chargeResult, "retry_same_order", "the attempt can be retried");
  assertEquals(result.orderId, ORDER_ID, "retry names the original order");
  assertEquals(attempt?.values.status, "initiated", "the same attempt remains open");
  assertEquals(attempt?.values.charge_dispatched_at, null, "the same order can be dispatched again");
  assertEquals(inserts.length, 0, "not-found does not record a payment");
  assertEquals(
    updates.filter((update) => update.table === "gyms").length,
    0,
    "not-found is not a card failure",
  );
});

Deno.test("reconciliation attempt pass queries orderId and does not charge on replay", async () => {
  const methods: string[] = [];
  const updates: Array<Record<string, unknown>> = [];
  const admin = {
    from() {
      return {
        update(values: Record<string, unknown>) {
          return {
            async eq() {
              updates.push(values);
              return { error: null };
            },
          };
        },
      };
    },
    async rpc() {
      return { data: { ok: true }, error: null };
    },
  };
  const attempt = {
    id: "attempt_1",
    gym_id: "gym_1",
    order_id: ORDER_ID,
    amount_krw: 10000,
    customer_key: "customer_1",
    billing_key_ref: "billing_key_1",
    status: "charge_failed",
    activation_status: "not_started",
    recovery_status: "pending",
    payment_key: null,
    reconciliation_action: "lookup_required" as const,
    target_period_start: "2026-01-01T00:00:00.000Z",
    target_period_end: "2026-02-01T00:00:00.000Z",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
  };
  const fetchImpl: typeof fetch = async (_input, init) => {
    const method = String(init?.method || "GET");
    methods.push(method);
    if (method === "POST") throw new Error("reconciliation charged an order");
    return new Response(JSON.stringify({ code: "NOT_FOUND_PAYMENT" }), { status: 404 });
  };

  const first = await processReconciliationAttempt(admin, attempt, {
    tossSecret: "test_secret",
    fetchImpl,
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });
  const second = await processReconciliationAttempt(admin, attempt, {
    tossSecret: "test_secret",
    fetchImpl,
    now: () => new Date("2026-01-01T00:20:00.000Z"),
  });

  assertEquals(methods, ["GET", "GET"], "each pass only looks the order up");
  assertEquals(first.providerPosts, 0, "first pass does not charge");
  assertEquals(second.providerPosts, 0, "replayed pass does not charge");
  assertEquals(first.sameOrderRetry, true, "not-found retries the same order");
  assertEquals(updates[0].charge_dispatched_at, null, "dispatch stays released");
  assertEquals(updates[1].status, "initiated", "replay does not open a new order");
});

Deno.test("unparsed order lookup body is masked before it can be stored", async () => {
  const secretBody =
    "not-json paymentKey=synthetic-payment-key billingKey=synthetic-billing-key cardNumber=4111111111111111";
  const fetchImpl: typeof fetch = async () =>
    new Response(secretBody, {
      status: 200,
      headers: { "content-type": "text/plain" },
    });

  const lookup = await lookupTossPaymentByOrderId(
    ORDER_ID,
    "synthetic-toss-secret",
    fetchImpl,
  );
  const settlement = classifyOrderLookup(lookup, {
    orderId: ORDER_ID,
    amountKrw: 10000,
  });
  const stored = JSON.stringify(sanitizeProviderPayload(settlement.payload));

  assertEquals(settlement.kind, "needs_review", "unparsed 200 stays in review");
  assert(stored.includes(REDACTED), "stored fallback uses the shared mask");
  assert(!stored.includes("synthetic-payment-key"), "payment key was stored");
  assert(!stored.includes("synthetic-billing-key"), "billing key was stored");
  assert(!stored.includes("4111111111111111"), "card number was stored");
  assert(!stored.includes("not-json"), "raw provider body was stored");
});

Deno.test("unparsed lookup error body is masked before it can be stored", async () => {
  const secretBody = "gateway paymentKey=synthetic-payment-key";
  const lookup = await lookupTossPaymentByOrderId(
    ORDER_ID,
    "synthetic-toss-secret",
    async () => new Response(secretBody, { status: 502 }),
  );
  const settlement = classifyOrderLookup(lookup, {
    orderId: ORDER_ID,
    amountKrw: 10000,
  });
  const stored = JSON.stringify(sanitizeProviderPayload(settlement.payload));

  assertEquals(settlement.kind, "pending", "unparsed 502 stays pending");
  assert(stored.includes(REDACTED), "stored error fallback uses the shared mask");
  assert(!stored.includes("synthetic-payment-key"), "payment key was stored");
  assert(!stored.includes("gateway"), "raw error body was stored");
});
