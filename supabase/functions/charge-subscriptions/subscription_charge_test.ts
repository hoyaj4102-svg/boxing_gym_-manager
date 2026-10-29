import {
  type AdminClientLike,
  type ClaimedSubscriptionCharge,
  processClaimedSubscriptionCharge,
} from "./subscription_charge.ts";

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

function baseClaim(
  overrides: Partial<ClaimedSubscriptionCharge> = {},
): ClaimedSubscriptionCharge {
  return {
    payment_attempt_id: "attempt_1",
    gym_id: "gym_1",
    user_id: "user_1",
    order_id: "toss_renew_attempt_1",
    customer_key: "customer_1",
    billing_key_ref: "billing_key_1",
    target_period_start: "2026-01-01T00:00:00.000Z",
    target_period_end: "2026-02-01T00:00:00.000Z",
    amount_krw: 10000,
    ...overrides,
  };
}

function createMockAdmin(options: {
  updateErrorFor?: (
    update: {
      table: string;
      values: Record<string, unknown>;
      column: string;
      value: string;
    },
  ) => null | { message: string; code?: string };
  rpcError?: null | { message: string; code?: string };
  rpcData?: unknown;
} = {}) {
  const updates: Array<{
    table: string;
    values: Record<string, unknown>;
    column: string;
    value: string;
  }> = [];
  const inserts: Array<{ table: string; values: Record<string, unknown> }> = [];
  const rpcCalls: Array<{ name: string; args: Record<string, unknown> }> = [];

  const admin: AdminClientLike = {
    from(table: string) {
      return {
        update(values: Record<string, unknown>) {
          return {
            async eq(column: string, value: string) {
              const update = { table, values, column, value };
              updates.push(update);
              return { error: options.updateErrorFor?.(update) ?? null };
            },
          };
        },
        async insert(values: Record<string, unknown>) {
          inserts.push({ table, values });
          return { error: null };
        },
      };
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcCalls.push({ name, args });
      return {
        data: options.rpcData ??
          { ok: true, payment_attempt_id: args.p_attempt_id },
        error: options.rpcError ?? null,
      };
    },
  };

  return { admin, updates, inserts, rpcCalls };
}

function updatesFor(
  updates: Array<{ table: string; values: Record<string, unknown> }>,
  table: string,
) {
  return updates.filter((update) => update.table === table);
}

Deno.test("auto-renewal success stores paymentKey, inserts checkout session, and activates", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin();
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      fetchCalls += 1;
      assertEquals(
        String(init?.method || "GET"),
        "POST",
        "charge must POST once",
      );
      return new Response(
        JSON.stringify({
          paymentKey: "payment_1",
          orderId: "toss_renew_attempt_1",
          status: "DONE",
          totalAmount: 10000,
        }),
        { status: 200 },
      );
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(fetchCalls, 1, "success should not retry POST");
  assertEquals(result.ok, true, "success should return ok");
  assertEquals(rpcCalls.length, 1, "success should activate attempt");
  assertEquals(inserts.length, 1, "success should insert checkout session");
  assertEquals(
    updatesFor(updates, "payment_attempts")[0].values.payment_key,
    "payment_1",
    "paymentKey must come from Toss response",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "success should not mark gym past_due",
  );
});

Deno.test("clear auto-renewal rejection marks past_due and does not recover", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin();

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(
        JSON.stringify({ code: "REJECT_CARD_COMPANY", message: "declined" }),
        { status: 400 },
      ),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(result.ok, false, "rejection should fail");
  assertEquals(result.chargeResult, "rejected", "rejection should be explicit");
  assertEquals(rpcCalls.length, 0, "rejection should not recover");
  assertEquals(
    inserts.length,
    0,
    "rejection should not insert checkout session",
  );
  assertEquals(
    updatesFor(updates, "payment_attempts")[0].values.recovery_status,
    "none",
    "clear rejection is not recovery pending",
  );
  assertEquals(
    updatesFor(updates, "gyms")[0].values.subscription_status,
    "past_due",
    "clear rejection should keep existing past_due policy",
  );
});

async function assertUncertainOutcome(
  name: string,
  fetchImpl: typeof fetch,
  expectedCode: string,
) {
  await Deno.test(name, async () => {
    const { admin, updates, inserts, rpcCalls } = createMockAdmin();
    let fetchCalls = 0;

    const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
      tossSecret: "test_secret",
      fetchImpl: async (input, init) => {
        fetchCalls += 1;
        return fetchImpl(input, init);
      },
      now: () => new Date("2026-01-01T00:10:00.000Z"),
    });

    const attemptUpdate = updatesFor(updates, "payment_attempts")[0];
    assertEquals(fetchCalls, 1, "uncertain outcome must not retry POST");
    assertEquals(result.ok, false, "uncertain outcome should fail safely");
    assertEquals(
      result.chargeResult,
      "uncertain",
      "result should be uncertain",
    );
    assertEquals(
      rpcCalls.length,
      0,
      "uncertain outcome should not recover yet",
    );
    assertEquals(
      inserts.length,
      0,
      "uncertain outcome should not insert checkout session",
    );
    assertEquals(
      attemptUpdate.values.recovery_status,
      "pending",
      "uncertain outcome should remain recovery pending",
    );
    assertEquals(
      attemptUpdate.values.error_code,
      expectedCode,
      "uncertain outcome should keep a distinct error code",
    );
    assertEquals(
      updatesFor(updates, "gyms").length,
      0,
      "uncertain outcome must not mark gym past_due or disable auto_renew",
    );
  });
}

await assertUncertainOutcome(
  "network error is uncertain and does not mark gym past_due",
  async () => {
    throw new TypeError("network dropped after approval");
  },
  "TOSS_CHARGE_NETWORK_UNCERTAIN",
);

await assertUncertainOutcome(
  "5xx is uncertain and does not mark gym past_due",
  async () =>
    new Response(JSON.stringify({ code: "SERVER_ERROR" }), { status: 500 }),
  "TOSS_CHARGE_HTTP_UNCERTAIN",
);

await assertUncertainOutcome(
  "429 is uncertain and does not mark gym past_due",
  async () =>
    new Response(JSON.stringify({ code: "TOO_MANY_REQUESTS" }), {
      status: 429,
    }),
  "TOSS_CHARGE_HTTP_UNCERTAIN",
);

await assertUncertainOutcome(
  "malformed success JSON is uncertain and does not mark gym past_due",
  async () => new Response("{", { status: 200 }),
  "TOSS_CHARGE_RESPONSE_UNCERTAIN",
);

await assertUncertainOutcome(
  "missing paymentKey is uncertain and does not use orderId fallback",
  async () =>
    new Response(
      JSON.stringify({
        orderId: "toss_renew_attempt_1",
        status: "DONE",
        totalAmount: 10000,
      }),
      { status: 200 },
    ),
  "TOSS_CHARGE_PAYMENT_KEY_MISSING_UNCERTAIN",
);

Deno.test("paymentKey save failure after successful charge keeps gym out of past_due", async () => {
  const { admin, updates, rpcCalls } = createMockAdmin({
    updateErrorFor: (update) =>
      update.table === "payment_attempts" &&
        update.values.status === "activation_pending"
        ? { message: "durable write failed", code: "XX000" }
        : null,
  });

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      }),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(result.ok, false, "durable write failure should be reported");
  assertEquals(rpcCalls.length, 0, "failed durable save should not activate");
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "post-charge DB failure must not mark gym past_due",
  );
});

Deno.test("activation failure leaves attempt recoverable and keeps gym out of past_due", async () => {
  const { admin, updates, rpcCalls } = createMockAdmin({
    rpcError: { message: "activation failed", code: "XX000" },
  });

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      }),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  const activationFailure = updatesFor(updates, "payment_attempts").find(
    (update) => update.values.status === "activation_failed",
  );
  assertEquals(result.ok, false, "activation failure should be reported");
  assertEquals(rpcCalls.length, 1, "activation should be attempted once");
  assert(activationFailure, "activation failure should update attempt");
  assertEquals(
    activationFailure?.values.recovery_status,
    "pending",
    "activation failure should remain recoverable",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "post-charge activation failure must not mark gym past_due",
  );
});
