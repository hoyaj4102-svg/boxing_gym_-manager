import { chargeIdempotencyKey } from "./toss_idempotency.ts";
import { chargeTossBilling } from "./toss_charge_outcome.ts";
import { isDuplicateWebhookTerminal } from "../toss-webhook/merchant_validation.ts";
import {
  type AdminClientLike,
  type ClaimedSubscriptionCharge,
  processClaimedSubscriptionCharge,
} from "../charge-subscriptions/subscription_charge.ts";

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

type StoredApproval = {
  body: string;
  orderId: string;
  paymentKey: string;
  payload: Record<string, unknown>;
};

type MockState = {
  approveCount: number;
  keys: string[];
  charges: Map<string, StoredApproval>;
  activations: number;
  webhookEvents: Map<string, string>;
  activatedOrders: Set<string>;
};

function createState(): MockState {
  return {
    approveCount: 0,
    keys: [],
    charges: new Map(),
    activations: 0,
    webhookEvents: new Map(),
    activatedOrders: new Set(),
  };
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function enqueue(
  chains: Map<string, Promise<void>>,
  key: string,
  task: () => Promise<void>,
) {
  const previous = chains.get(key) ?? Promise.resolve();
  const run = previous.then(task, task);
  chains.set(
    key,
    run.then(() => undefined, () => undefined),
  );
  return run;
}

function disallowedProviderSecret(authorization: string) {
  const encoded = authorization.replace(/^Basic\s+/i, "").trim();
  try {
    const decoded = atob(encoded);
    return decoded.includes("test_sk_") || decoded.includes("live_sk_") ||
      decoded.includes("test_gsk_") || decoded.includes("live_gsk_");
  } catch {
    return false;
  }
}

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function paymentForOrder(state: MockState, orderId: string) {
  for (const stored of state.charges.values()) {
    if (stored.orderId === orderId) return stored;
  }
  return null;
}

function applyWebhookDelivery(
  state: MockState,
  transmissionId: string,
  orderId: string,
) {
  const existing = state.webhookEvents.get(transmissionId);
  if (existing && isDuplicateWebhookTerminal(existing)) {
    return {
      ok: true,
      duplicate: true,
      activations: state.activations,
    };
  }

  const payment = paymentForOrder(state, orderId);
  if (!payment) {
    state.webhookEvents.set(transmissionId, "not_found");
    return {
      ok: true,
      ignored: true,
      reason: "payment_not_found",
      activations: state.activations,
    };
  }

  if (state.activatedOrders.has(orderId)) {
    state.webhookEvents.set(transmissionId, "already_completed");
    return {
      ok: true,
      duplicate: true,
      alreadyCompleted: true,
      activations: state.activations,
    };
  }

  state.activatedOrders.add(orderId);
  state.activations += 1;
  state.webhookEvents.set(transmissionId, "processed");
  return {
    ok: true,
    processed: true,
    activations: state.activations,
    paymentKey: payment.paymentKey,
  };
}

function handleMockToss(state: MockState, chains: Map<string, Promise<void>>) {
  return async (req: Request) => {
    const url = new URL(req.url);
    if (url.hostname !== "127.0.0.1") {
      return jsonResponse({ code: "NON_LOOPBACK" }, 400);
    }

    if (req.method === "GET" && url.pathname.startsWith("/v1/payments/orders/")) {
      const orderId = decodeURIComponent(
        url.pathname.slice("/v1/payments/orders/".length),
      );
      const payment = paymentForOrder(state, orderId);
      if (!payment) return jsonResponse({ code: "NOT_FOUND" }, 404);
      return jsonResponse(payment.payload);
    }

    if (req.method === "POST" && url.pathname === "/mock-webhook") {
      const transmissionId = req.headers.get(
        "tosspayments-webhook-transmission-id",
      ) || "";
      const payload = await req.json() as { data?: { orderId?: string } };
      const orderId = String(payload.data?.orderId || "");
      let result: Record<string, unknown> = { ok: false };
      await enqueue(chains, `webhook:${transmissionId}`, async () => {
        result = applyWebhookDelivery(state, transmissionId, orderId);
      });
      return jsonResponse(result);
    }

    const billingMatch = url.pathname.match(/^\/v1\/billing\/([^/]+)$/);
    if (req.method !== "POST" || !billingMatch) {
      return jsonResponse({ code: "NOT_FOUND" }, 404);
    }

    const authorization = req.headers.get("authorization") || "";
    if (disallowedProviderSecret(authorization)) {
      return jsonResponse({ code: "LIVE_OR_TEST_KEY_REFUSED" }, 400);
    }

    const idempotencyKey = req.headers.get("idempotency-key") || "";
    const delayMs = Number(req.headers.get("x-mock-delay-ms") || "0");
    let response = jsonResponse({ code: "UNHANDLED" }, 500);
    await enqueue(chains, idempotencyKey || "missing-key", async () => {
      const bodyText = await req.text();
      if (!idempotencyKey) {
        response = jsonResponse({ code: "IDEMPOTENCY_KEY_REQUIRED" }, 400);
        return;
      }
      state.keys.push(idempotencyKey);
      const existing = state.charges.get(idempotencyKey);
      if (existing) {
        if (existing.body !== bodyText) {
          response = jsonResponse({
            code: "IDEMPOTENT_REQUEST_MISMATCH",
            message: "same key with a different approval body",
          }, 400);
          return;
        }
        response = jsonResponse(existing.payload);
        return;
      }

      const body = JSON.parse(bodyText) as { orderId?: string; amount?: number };
      state.approveCount += 1;
      const paymentKey = `pay_local_${state.approveCount}`;
      const payload = {
        paymentKey,
        orderId: String(body.orderId || ""),
        status: "DONE",
        totalAmount: Number(body.amount || 0),
        mId: "mid_local",
      };
      state.charges.set(idempotencyKey, {
        body: bodyText,
        orderId: payload.orderId,
        paymentKey,
        payload,
      });
      if (delayMs > 0) await sleep(delayMs);
      response = jsonResponse(payload);
    });
    return response;
  };
}

async function withMockToss(
  run: (base: string, state: MockState) => Promise<void>,
) {
  const state = createState();
  const chains = new Map<string, Promise<void>>();
  const server = Deno.serve({
    hostname: "127.0.0.1",
    port: 0,
    onListen() {},
  }, handleMockToss(state, chains));
  try {
    const addr = server.addr as Deno.NetAddr;
    await run(`http://127.0.0.1:${addr.port}`, state);
  } finally {
    await server.shutdown();
  }
}

function rewriteToMock(base: string, input: Parameters<typeof fetch>[0]) {
  const raw = typeof input === "string"
    ? input
    : input instanceof URL
    ? input.href
    : input.url;
  const url = new URL(raw);
  if (url.protocol !== "https:" || url.hostname !== "api.tosspayments.com") {
    throw new Error("REFUSING_NON_TOSS_URL");
  }
  const local = new URL(`${url.pathname}${url.search}`, base);
  if (local.hostname !== "127.0.0.1") {
    throw new Error("REFUSING_NON_LOOPBACK");
  }
  return local.href;
}

function mockFetch(
  base: string,
  state: MockState,
  options: { delayMs?: number; abortAfterCommit?: boolean } = {},
): typeof fetch {
  return async (input, init) => {
    const headers = new Headers(init?.headers);
    if (options.delayMs) {
      headers.set("x-mock-delay-ms", String(options.delayMs));
    }
    const controller = new AbortController();
    const responsePromise = fetch(rewriteToMock(base, input), {
      method: init?.method,
      headers,
      body: init?.body,
      signal: controller.signal,
    });
    if (options.abortAfterCommit) {
      const started = Date.now();
      while (state.approveCount < 1) {
        if (Date.now() - started > 2000) {
          throw new Error("mock approval was not committed before timeout");
        }
        await sleep(5);
      }
      controller.abort();
    }
    return await responsePromise;
  };
}

function renewalClaim(orderId: string): ClaimedSubscriptionCharge {
  return {
    payment_attempt_id: "attempt_local_1",
    gym_id: "gym_local_1",
    user_id: "user_local_1",
    order_id: orderId,
    customer_key: "customer_local_1",
    billing_key_ref: "billing_local_1",
    target_period_start: "2026-01-01T00:00:00.000Z",
    target_period_end: "2026-02-01T00:00:00.000Z",
    amount_krw: 10000,
  };
}

function renewalAdmin() {
  const updates: Array<{ table: string; values: Record<string, unknown> }> = [];
  const admin: AdminClientLike = {
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
          return { error: null };
        },
      };
    },
    async rpc(name: string, args: Record<string, unknown>) {
      if (name === "read_gym_billing_credential") {
        return { data: "billing_local_1", error: null };
      }
      if (name === "claim_subscription_charge_dispatch") {
        return { data: true, error: null };
      }
      return {
        data: { ok: true, payment_attempt_id: args.p_attempt_id },
        error: null,
      };
    },
  };
  return { admin, updates };
}

function paymentKeys(
  updates: Array<{ table: string; values: Record<string, unknown> }>,
) {
  return updates
    .filter((update) =>
      update.table === "payment_attempts" &&
      typeof update.values.payment_key === "string"
    )
    .map((update) => update.values.payment_key);
}

async function renew(
  base: string,
  state: MockState,
  orderId: string,
  options: { delayMs?: number; abortAfterCommit?: boolean } = {},
) {
  const { admin, updates } = renewalAdmin();
  const result = await processClaimedSubscriptionCharge(
    admin,
    renewalClaim(orderId),
    {
      tossSecret: "local-only",
      fetchImpl: mockFetch(base, state, options),
    },
  );
  return { result, updates };
}

async function postWebhook(
  base: string,
  transmissionId: string,
  orderId: string,
  paymentKey: string,
) {
  const response = await fetch(`${base}/mock-webhook`, {
    method: "POST",
    headers: {
      "content-type": "application/json",
      "tosspayments-webhook-transmission-id": transmissionId,
    },
    body: JSON.stringify({
      eventType: "PAYMENT_STATUS_CHANGED",
      data: { orderId, paymentKey, status: "DONE" },
    }),
  });
  return await response.json();
}

Deno.test("charge idempotency key is stable for one payment attempt", () => {
  const orderId = "toss_renew_attempt_local_1";
  assertEquals(
    chargeIdempotencyKey(orderId),
    chargeIdempotencyKey(orderId),
    "retries of one attempt must build the same key",
  );
  assert(
    chargeIdempotencyKey(orderId) !==
      chargeIdempotencyKey("toss_renew_attempt_local_2"),
    "a different attempt must build a different key",
  );
  let rejected = false;
  try {
    chargeIdempotencyKey("");
  } catch (error) {
    rejected = error instanceof Error &&
      error.message === "IDEMPOTENCY_KEY_INVALID";
  }
  assert(rejected, "an empty attempt id must not become a provider key");
});

Deno.test("duplicate billing approvals reuse one idempotency key", async () => {
  const orderId = "toss_renew_attempt_local_1";
  const expectedKey = chargeIdempotencyKey(orderId);

  await withMockToss(async (base, state) => {
    const first = await renew(base, state, orderId);
    const second = await renew(base, state, orderId);

    assertEquals(first.result.ok, true, "first approval should succeed");
    assertEquals(second.result.ok, true, "duplicate approval should replay");
    assertEquals(state.approveCount, 1, "duplicate request must not charge again");
    assertEquals(
      state.keys,
      [expectedKey, expectedKey],
      "both requests must send the attempt key",
    );
    assertEquals(
      paymentKeys(first.updates),
      ["pay_local_1"],
      "first result keeps the mock payment",
    );
    assertEquals(
      paymentKeys(second.updates),
      ["pay_local_1"],
      "replay returns the original payment",
    );

    const mismatch = await chargeTossBilling({
      billingKey: "billing_local_1",
      authorization: "Basic local-only",
      body: {
        customerKey: "customer_local_1",
        amount: 20000,
        orderId,
        orderName: "re;member Pro monthly",
      },
      fetchImpl: mockFetch(base, state),
    });
    assertEquals(mismatch.kind, "rejected", "a different body is not a replay");
    assertEquals(
      mismatch.kind === "rejected" ? mismatch.code : null,
      "IDEMPOTENT_REQUEST_MISMATCH",
      "the mock should reject a changed approval body",
    );
    assertEquals(
      state.approveCount,
      1,
      "a mismatched retry must not create another charge",
    );

    const other = await renew(base, state, "toss_renew_attempt_local_2");
    assertEquals(other.result.ok, true, "a new attempt can be approved");
    assertEquals(state.approveCount, 2, "a new attempt is a separate charge");
  });
});

Deno.test("retry after timeout reuses the same idempotency key", async () => {
  const orderId = "toss_bill_attempt_local_1";
  const expectedKey = chargeIdempotencyKey(orderId);

  await withMockToss(async (base, state) => {
    const timedOut = await renew(base, state, orderId, {
      delayMs: 300,
      abortAfterCommit: true,
    });
    assertEquals(timedOut.result.ok, false, "timeout is not a success");
    assertEquals(
      timedOut.result.chargeResult,
      "uncertain",
      "timeout stays uncertain instead of a decline",
    );
    assertEquals(
      timedOut.updates.filter((update) => update.table === "gyms").length,
      0,
      "timeout must not mark the gym past_due",
    );
    assertEquals(state.approveCount, 1, "the timed out request was still approved once");

    const retried = await renew(base, state, orderId);
    assertEquals(retried.result.ok, true, "retry should receive the stored approval");
    assertEquals(state.approveCount, 1, "retry must not approve a second time");
    assertEquals(
      state.keys.every((key) => key === expectedKey),
      true,
      "timeout and retry must send the same key",
    );
    assertEquals(
      paymentKeys(retried.updates),
      ["pay_local_1"],
      "retry stores the original payment",
    );
  });
});

Deno.test("concurrent billing approvals charge once", async () => {
  const orderId = "toss_renew_attempt_local_1";

  await withMockToss(async (base, state) => {
    const [left, right] = await Promise.all([
      renew(base, state, orderId, { delayMs: 40 }),
      renew(base, state, orderId, { delayMs: 40 }),
    ]);

    assertEquals(left.result.ok, true, "first concurrent approval should succeed");
    assertEquals(right.result.ok, true, "second concurrent approval should succeed");
    assertEquals(state.approveCount, 1, "concurrent execution must charge once");
    assertEquals(
      paymentKeys(left.updates),
      ["pay_local_1"],
      "first concurrent result uses the only payment",
    );
    assertEquals(
      paymentKeys(right.updates),
      ["pay_local_1"],
      "second concurrent result uses the only payment",
    );
    assertEquals(
      new Set(state.keys).size,
      1,
      "concurrent calls must share one idempotency key",
    );
  });
});

Deno.test("duplicate webhook delivery activates once", async () => {
  const orderId = "toss_renew_attempt_local_1";

  await withMockToss(async (base, state) => {
    const charged = await renew(base, state, orderId);
    assertEquals(charged.result.ok, true, "webhook fixture needs one approval");
    const paymentKey = paymentKeys(charged.updates)[0];

    const first = await postWebhook(base, "tx_local_1", orderId, String(paymentKey));
    const second = await postWebhook(base, "tx_local_1", orderId, String(paymentKey));
    const [third, fourth] = await Promise.all([
      postWebhook(base, "tx_local_1", orderId, String(paymentKey)),
      postWebhook(base, "tx_local_1", orderId, String(paymentKey)),
    ]);
    const otherTransmission = await postWebhook(
      base,
      "tx_local_2",
      orderId,
      String(paymentKey),
    );

    assertEquals(first.processed, true, "first delivery should activate");
    assertEquals(first.activations, 1, "first delivery activates once");
    assertEquals(second.duplicate, true, "replayed transmission is a duplicate");
    assertEquals(second.activations, 1, "replayed transmission does not activate again");
    assertEquals(third.activations, 1, "concurrent replay stays at one activation");
    assertEquals(fourth.activations, 1, "concurrent replay stays at one activation");
    assertEquals(
      otherTransmission.alreadyCompleted,
      true,
      "a second transmission of the same payment does not activate again",
    );
    assertEquals(state.activations, 1, "duplicate delivery keeps a single activation");
    assertEquals(state.approveCount, 1, "webhook delivery must not approve again");

    const lookup = await fetch(
      `${base}/v1/payments/orders/${encodeURIComponent(orderId)}`,
    );
    const body = await lookup.json();
    assertEquals(lookup.status, 200, "order lookup should find the one payment");
    assertEquals(body.paymentKey, "pay_local_1", "lookup returns the stored payment");
    assertEquals(body.orderId, orderId, "lookup order matches the attempt");
  });
});
