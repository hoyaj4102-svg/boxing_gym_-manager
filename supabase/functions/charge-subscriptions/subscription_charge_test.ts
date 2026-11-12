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
  insertErrorFor?: (
    insert: {
      table: string;
      values: Record<string, unknown>;
    },
  ) => null | { message: string; code?: string };
  rpcError?: null | { message: string; code?: string };
  rpcData?: unknown;
  billingCredential?: string | null;
  billingCredentialError?: null | { message: string; code?: string };
  dispatchResult?: boolean;
  dispatchError?: null | { message: string; code?: string };
  rpcByName?: Record<string, {
    data: unknown;
    error: null | { message: string; code?: string };
  }>;
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
          const insert = { table, values };
          inserts.push(insert);
          return { error: options.insertErrorFor?.(insert) ?? null };
        },
      };
    },
    async rpc(name: string, args: Record<string, unknown>) {
      rpcCalls.push({ name, args });
      if (name === "read_gym_billing_credential") {
        return {
          data: options.billingCredentialError
            ? null
            : options.billingCredential ?? null,
          error: options.billingCredentialError ?? null,
        };
      }
      if (name === "claim_subscription_charge_dispatch") {
        return {
          data: options.dispatchResult ?? true,
          error: options.dispatchError ?? null,
        };
      }
      if (options.rpcByName?.[name]) return options.rpcByName[name];
      if (
        name === "billing_charge_consent_gate" ||
        name === "record_payment_failure"
      ) {
        return { data: { ok: true }, error: null };
      }
      return {
        data: options.rpcData ??
          { ok: true, payment_attempt_id: args.p_attempt_id },
        error: options.rpcError ?? null,
      };
    },
  };

  return { admin, updates, inserts, rpcCalls };
}

function activationRpcCount(
  rpcCalls: Array<{ name: string }>,
) {
  return rpcCalls.filter((call) => call.name === "activate_payment_attempt")
    .length;
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
  assertEquals(activationRpcCount(rpcCalls), 1, "success should activate attempt");
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
  assertEquals(activationRpcCount(rpcCalls), 0, "rejection should not recover");
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

Deno.test("rejected charge persistence failure does not mark gym past_due", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin({
    updateErrorFor: (update) =>
      update.table === "payment_attempts" &&
        update.values.status === "charge_failed" &&
        update.values.error_code === "REJECT_CARD_COMPANY"
        ? { message: "rejection write failed", code: "XX000" }
        : null,
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(
        JSON.stringify({ code: "REJECT_CARD_COMPANY", message: "declined" }),
        { status: 400 },
      );
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(fetchCalls, 1, "rejected charge must not retry POST");
  assertEquals(result.ok, false, "failed rejection write should be reported");
  assertEquals(
    result.chargeResult,
    "rejected_persist_failed",
    "caller should see that rejected state was not saved",
  );
  assertEquals(
    result.retryable,
    true,
    "failed rejection write should be retryable",
  );
  assertEquals(
    updatesFor(updates, "payment_attempts").length,
    1,
    "failed rejection write should not be hidden by a second attempt update",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "gym must not be marked past_due without durable rejection state",
  );
  assertEquals(
    inserts.length,
    0,
    "failed rejection write should not insert checkout session",
  );
  assertEquals(activationRpcCount(rpcCalls), 0, "failed rejection write should not recover");
});

Deno.test("missing Toss secret is an internal retryable error and does not mark past_due", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin();
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "",
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new Error("fetch should not be called");
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  const attemptUpdate = updatesFor(updates, "payment_attempts")[0];
  assertEquals(fetchCalls, 0, "missing secret must fail before Toss POST");
  assertEquals(result.ok, false, "missing secret should fail safely");
  assertEquals(
    result.chargeResult,
    "internal_error",
    "missing secret should not be a card rejection",
  );
  assertEquals(result.retryable, true, "internal errors should be retryable");
  assertEquals(
    attemptUpdate.values.error_code,
    "AUTO_RENEW_TOSS_SECRET_MISSING",
    "attempt should keep an operator-visible error code",
  );
  assertEquals(
    attemptUpdate.values.recovery_status,
    "none",
    "pre-Toss errors should remain stale-claim eligible after the delay",
  );
  assertEquals(activationRpcCount(rpcCalls), 0, "pre-Toss errors should not recover");
  assertEquals(
    inserts.length,
    0,
    "pre-Toss errors should not insert checkout session",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "internal errors must not mark gym past_due or disable auto_renew",
  );
});

Deno.test("invalid claim data is an internal retryable error and does not mark past_due", async () => {
  const { admin, updates, rpcCalls } = createMockAdmin();
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(
    admin,
    baseClaim({ billing_key_ref: "" }),
    {
      tossSecret: "test_secret",
      fetchImpl: async () => {
        fetchCalls += 1;
        throw new Error("fetch should not be called");
      },
      now: () => new Date("2026-01-01T00:10:00.000Z"),
    },
  );

  const attemptUpdate = updatesFor(updates, "payment_attempts")[0];
  assertEquals(fetchCalls, 0, "invalid claim must fail before Toss POST");
  assertEquals(
    result.chargeResult,
    "internal_error",
    "invalid claim should not be a card rejection",
  );
  assertEquals(result.retryable, true, "invalid claim should be retryable");
  assertEquals(
    attemptUpdate.values.error_code,
    "AUTO_RENEW_CLAIM_INVALID",
    "attempt should keep an operator-visible error code",
  );
  assertEquals(activationRpcCount(rpcCalls), 0, "invalid claim should not recover");
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "invalid claim must not mark gym past_due or disable auto_renew",
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
      activationRpcCount(rpcCalls),
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

Deno.test("uncertain recovery-state write failure is reported without marking past_due", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin({
    updateErrorFor: (update) =>
      update.table === "payment_attempts" &&
        update.values.status === "charge_failed" &&
        update.values.recovery_status === "pending"
        ? { message: "pending write failed", code: "XX000" }
        : null,
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      throw new TypeError("network dropped after approval");
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(fetchCalls, 1, "uncertain charge must not retry POST");
  assertEquals(result.ok, false, "failed pending write should be reported");
  assertEquals(
    result.chargeResult,
    "uncertain_persist_failed",
    "caller should see that recovery pending state was not saved",
  );
  assertEquals(
    result.retryable,
    true,
    "failed pending write remains retryable",
  );
  assertEquals(
    updatesFor(updates, "payment_attempts").length,
    1,
    "failed pending write should not be hidden by a second attempt update",
  );
  assertEquals(
    activationRpcCount(rpcCalls),
    0,
    "failed pending write should not activate",
  );
  assertEquals(
    inserts.length,
    0,
    "failed pending write should not insert checkout session",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "failed pending write must not mark gym past_due or disable auto_renew",
  );
});

Deno.test("paymentKey save failure after successful charge keeps gym out of past_due", async () => {
  const { admin, updates, rpcCalls } = createMockAdmin({
    updateErrorFor: (update) =>
      update.table === "payment_attempts" &&
        update.values.status === "activation_pending"
        ? { message: "durable write failed", code: "XX000" }
        : null,
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(fetchCalls, 1, "successful charge must not retry POST");
  assertEquals(result.ok, false, "durable write failure should be reported");
  assertEquals(activationRpcCount(rpcCalls), 0, "failed durable save should not activate");
  assertEquals(
    updatesFor(updates, "payment_attempts").length,
    1,
    "failed paymentKey save should leave original attempt state for stale lookup",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "post-charge DB failure must not mark gym past_due",
  );
});

Deno.test("checkout session insert failure after successful charge stops before activation", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin({
    insertErrorFor: (insert) =>
      insert.table === "checkout_sessions"
        ? { message: "checkout history write failed", code: "XX000" }
        : null,
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  const attemptUpdates = updatesFor(updates, "payment_attempts");
  assertEquals(fetchCalls, 1, "successful charge must not retry POST");
  assertEquals(result.ok, false, "checkout insert failure should be reported");
  assert(
    String(result.error || "").includes("CHECKOUT_SESSION_INSERT_FAILED"),
    "checkout insert failure should be visible to the caller",
  );
  assertEquals(
    inserts.length,
    1,
    "checkout session insert should be attempted",
  );
  assertEquals(
    attemptUpdates.length,
    1,
    "checkout insert failure should leave one activation_pending attempt update",
  );
  assertEquals(
    attemptUpdates[0].values.status,
    "activation_pending",
    "paymentKey should remain available for recovery-only activation",
  );
  assertEquals(
    attemptUpdates[0].values.payment_key,
    "payment_1",
    "paymentKey should be preserved for recovery",
  );
  assertEquals(
    activationRpcCount(rpcCalls),
    0,
    "checkout insert failure should stop before activation",
  );
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "post-charge checkout insert failure must not mark gym past_due",
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
  assertEquals(activationRpcCount(rpcCalls), 1, "activation should be attempted once");
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

Deno.test("renewal charges the private credential and stores a sanitized payload", async () => {
  const stored = "stored-credential";
  const legacy = "legacy-claim-value";
  const cardNumber = "4111111111111111";
  const email = "member@example.test";
  const { admin, inserts, updates } = createMockAdmin({
    billingCredential: stored,
  });
  let chargedUrl = "";
  let chargedBody: Record<string, unknown> = {};

  const result = await processClaimedSubscriptionCharge(
    admin,
    baseClaim({ billing_key_ref: legacy }),
    {
      tossSecret: "test_secret",
      fetchImpl: async (input, init) => {
        chargedUrl = String(input);
        chargedBody = JSON.parse(String(init?.body || "{}"));
        return new Response(JSON.stringify({
          paymentKey: "payment_1",
          orderId: "toss_renew_attempt_1",
          status: "DONE",
          totalAmount: 10000,
          billingKey: stored,
          card: { number: cardNumber },
          customerEmail: email,
          customerKey: "customer_1",
        }), { status: 200 });
      },
      now: () => new Date("2026-01-01T00:10:00.000Z"),
    },
  );

  const raw = JSON.stringify(inserts[0]?.values.raw ?? null);
  const providerResponse = JSON.stringify(
    updatesFor(updates, "payment_attempts")[0]?.values.provider_response ??
      null,
  );
  assertEquals(result.ok, true, "private credential should still charge");
  assert(
    chargedUrl.includes(encodeURIComponent(stored)),
    "charge uses the private credential",
  );
  assert(
    !chargedUrl.includes(legacy),
    "charge does not use the legacy claim field",
  );
  assertEquals(chargedBody.amount, 10000, "charge amount stays unchanged");
  assert(!raw.includes(stored), "stored credential is not written to checkout");
  assert(!raw.includes(cardNumber), "card number is not written to checkout");
  assert(!raw.includes(email), "customer email is not written to checkout");
  assert(!raw.includes("payment_1"), "payment key is not written to checkout raw");
  assert(raw.includes("[REDACTED]"), "checkout payload redacts sensitive fields");
  assertEquals(
    updatesFor(updates, "payment_attempts")[0]?.values.payment_key,
    "payment_1",
    "payment key column still comes from the charge response",
  );
  assert(
    !providerResponse.includes(stored),
    "stored credential is not written to the attempt payload",
  );
  assert(
    !providerResponse.includes(cardNumber),
    "card number is not written to the attempt payload",
  );
  assertEquals(
    updatesFor(updates, "payment_attempts")[0]?.values.billing_key_ref,
    undefined,
    "attempt update does not copy the credential",
  );
});

Deno.test("renewal keeps the claim credential when private storage is empty", async () => {
  const { admin } = createMockAdmin();
  let chargedUrl = "";
  let chargedBody: Record<string, unknown> = {};

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async (input, init) => {
      chargedUrl = String(input);
      chargedBody = JSON.parse(String(init?.body || "{}"));
      return new Response(JSON.stringify({
        paymentKey: "payment_1",
        orderId: "toss_renew_attempt_1",
        status: "DONE",
        totalAmount: 10000,
      }), { status: 200 });
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(result.ok, true, "legacy claim credential should still charge");
  assert(
    chargedUrl.includes(encodeURIComponent("billing_key_1")),
    "empty private storage falls back to the claim credential",
  );
  assertEquals(chargedBody.amount, 10000, "fallback charge amount stays unchanged");
});

Deno.test("renewal does not charge when the credential read is unavailable", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin({
    billingCredentialError: {
      message: "function does not exist",
      code: "PGRST202",
    },
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(fetchCalls, 0, "missing credential read must not call the provider");
  assertEquals(result.ok, false, "missing credential read fails closed");
  assertEquals(result.chargeResult, "credential_unavailable", "failure stays distinct");
  assertEquals(updates.length, 0, "missing credential read does not rewrite the attempt");
  assertEquals(inserts.length, 0, "missing credential read does not store a payload");
  assertEquals(
    updatesFor(updates, "gyms").length,
    0,
    "missing credential read must not mark the gym past due",
  );
  assertEquals(
    rpcCalls.some((call) => call.name === "claim_subscription_charge_dispatch"),
    false,
    "missing credential read must not dispatch a charge",
  );
});

Deno.test("dry run does not dispatch or call the provider", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin();
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    dryRun: true,
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
  });

  assertEquals(result.dryRun, true, "dry run should identify itself");
  assertEquals(result.providerCalls, 0, "dry run should report no provider calls");
  assertEquals(fetchCalls, 0, "dry run must not call the provider");
  assertEquals(rpcCalls.length, 0, "dry run must not dispatch or read credentials");
  assertEquals(updates.length, 0, "dry run must not rewrite an attempt");
  assertEquals(inserts.length, 0, "dry run must not insert a checkout session");
});

Deno.test("a second dispatch does not call the provider", async () => {
  const { admin, updates, inserts, rpcCalls } = createMockAdmin({
    dispatchResult: false,
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
  });

  assertEquals(fetchCalls, 0, "already dispatched attempt must not call the provider");
  assertEquals(result.ok, false, "already dispatched attempt should not succeed");
  assertEquals(result.chargeResult, "already_dispatched", "duplicate dispatch stays explicit");
  assertEquals(updates.length, 0, "duplicate dispatch must not rewrite the attempt");
  assertEquals(inserts.length, 0, "duplicate dispatch must not insert a checkout session");
  assertEquals(
    rpcCalls.filter((call) => call.name === "claim_subscription_charge_dispatch")
      .length,
    1,
    "dispatch should be checked once",
  );
});

Deno.test("dispatch unavailable does not call the provider", async () => {
  const { admin, updates } = createMockAdmin({
    dispatchError: { message: "function does not exist", code: "PGRST202" },
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), {
        status: 200,
      });
    },
  });

  assertEquals(fetchCalls, 0, "unavailable dispatch must not call the provider");
  assertEquals(result.chargeResult, "dispatch_unavailable", "failure stays distinct");
  assertEquals(updates.length, 0, "unavailable dispatch must not rewrite the attempt");
});

Deno.test("renewal sends a stable Idempotency-Key for the order", async () => {
  const { admin } = createMockAdmin();
  let idempotencyKey: string | null = null;

  await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      idempotencyKey = new Headers(init?.headers).get("Idempotency-Key");
      return new Response(JSON.stringify({
        paymentKey: "payment_1",
        orderId: "toss_renew_attempt_1",
      }), { status: 200 });
    },
  });

  assertEquals(
    idempotencyKey,
    "charge_toss_renew_attempt_1",
    "the charge reuses the order idempotency key",
  );
});

Deno.test("a denied price gate does not call Toss or mark past_due", async () => {
  const { admin, updates } = createMockAdmin({
    rpcByName: {
      billing_charge_consent_gate: {
        data: { allowed: false, code: "PRICE_NOT_AUTHORIZED" },
        error: null,
      },
    },
  });
  let fetchCalls = 0;

  const result = await processClaimedSubscriptionCharge(admin, baseClaim(), {
    tossSecret: "test_secret",
    fetchImpl: async () => {
      fetchCalls += 1;
      return new Response(JSON.stringify({ paymentKey: "payment_1" }), { status: 200 });
    },
  });

  assertEquals(fetchCalls, 0, "denied consent must not call Toss");
  assertEquals(result.chargeResult, "consent_blocked", "the charge result names the gate");
  assertEquals(updatesFor(updates, "gyms").length, 0, "a consent block is not a card failure");
  assertEquals(
    updatesFor(updates, "payment_attempts")[0].values.error_code,
    "PRICE_NOT_AUTHORIZED",
    "the attempt keeps the gate code",
  );
});
