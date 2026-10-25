import {
  processReconciliationAttempt,
  type ReconciliationAttempt,
} from "./reconciliation.ts";

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

function baseAttempt(
  overrides: Partial<ReconciliationAttempt> = {},
): ReconciliationAttempt {
  return {
    id: "attempt_1",
    gym_id: "gym_1",
    order_id: "toss_renew_attempt_1",
    amount_krw: 10000,
    customer_key: "customer_1",
    billing_key_ref: "billing_key_1",
    status: "initiated",
    activation_status: "not_started",
    recovery_status: "pending",
    payment_key: null,
    reconciliation_action: "lookup_required",
    target_period_start: "2026-01-01T00:00:00.000Z",
    target_period_end: "2026-02-01T00:00:00.000Z",
    created_at: "2026-01-01T00:00:00.000Z",
    updated_at: "2026-01-01T00:00:00.000Z",
    ...overrides,
  };
}

function createMockAdmin(
  rpcError: { code?: string; message: string } | null = null,
) {
  const updates: Array<
    {
      table: string;
      values: Record<string, unknown>;
      column: string;
      value: string;
    }
  > = [];
  const rpcCalls: Array<{ name: string; args: Record<string, unknown> }> = [];

  return {
    updates,
    rpcCalls,
    admin: {
      from(table: string) {
        return {
          update(values: Record<string, unknown>) {
            return {
              async eq(column: string, value: string) {
                updates.push({ table, values, column, value });
                return { error: null };
              },
            };
          },
        };
      },
      async rpc(name: string, args: Record<string, unknown>) {
        rpcCalls.push({ name, args });
        return {
          data: rpcError
            ? null
            : { ok: true, payment_attempt_id: args.p_attempt_id },
          error: rpcError,
        };
      },
    },
  };
}

Deno.test("recovery_only reuses existing payment_key without Toss lookup", async () => {
  const { admin, rpcCalls, updates } = createMockAdmin();
  let fetchCalls = 0;

  const result = await processReconciliationAttempt(
    admin,
    baseAttempt({
      status: "activation_failed",
      activation_status: "failed",
      payment_key: "payment_existing",
      reconciliation_action: "recovery_only",
    }),
    {
      tossSecret: "test_secret",
      fetchImpl: async () => {
        fetchCalls += 1;
        return new Response("{}");
      },
      now: () => new Date("2026-01-01T00:10:00.000Z"),
    },
  );

  assertEquals(fetchCalls, 0, "recovery_only should not call Toss lookup");
  assertEquals(rpcCalls.length, 1, "recovery_only should call recovery RPC");
  assertEquals(
    rpcCalls[0].name,
    "recover_payment_attempt_activation",
    "unexpected RPC",
  );
  assertEquals(
    updates.length,
    0,
    "successful recovery_only should not pre-update attempt",
  );
  assertEquals(result.ok, true, "recovery_only should succeed");
});

Deno.test("lookup_required uses Toss GET, stores payment_key, then recovers", async () => {
  const { admin, rpcCalls, updates } = createMockAdmin();
  const methods: string[] = [];

  const result = await processReconciliationAttempt(admin, baseAttempt(), {
    tossSecret: "test_secret",
    fetchImpl: async (_input, init) => {
      methods.push(String(init?.method || "GET"));
      return new Response(
        JSON.stringify({
          paymentKey: "payment_found",
          orderId: "toss_renew_attempt_1",
          status: "DONE",
          totalAmount: 10000,
        }),
        { status: 200 },
      );
    },
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(methods, ["GET"], "lookup_required should call Toss GET once");
  assertEquals(
    rpcCalls.length,
    1,
    "lookup_required should recover after storing payment",
  );
  assertEquals(
    updates[0].values.payment_key,
    "payment_found",
    "payment_key should be stored before recovery",
  );
  assertEquals(
    updates[0].values.status,
    "activation_pending",
    "attempt should move to activation_pending",
  );
  assertEquals(result.ok, true, "lookup_required DONE payment should recover");
});

Deno.test("lookup_required retryable Toss error is not terminal failed", async () => {
  const { admin, rpcCalls, updates } = createMockAdmin();

  const result = await processReconciliationAttempt(admin, baseAttempt(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(JSON.stringify({ message: "temporary" }), { status: 500 }),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(
    rpcCalls.length,
    0,
    "retryable lookup failure should not recover",
  );
  assertEquals(
    updates[0].values.recovery_status,
    "none",
    "retryable lookup should remain retryable",
  );
  assert(
    updates[0].values.recovery_status !== "failed",
    "retryable lookup must not be terminal failed",
  );
  assertEquals(
    result.retryable,
    true,
    "retryable lookup result should be retryable",
  );
});

Deno.test("lookup_required 404 stays blocked and does not allow a new charge", async () => {
  const { admin, rpcCalls, updates } = createMockAdmin();

  const result = await processReconciliationAttempt(admin, baseAttempt(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(JSON.stringify({ code: "NOT_FOUND" }), { status: 404 }),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(rpcCalls.length, 0, "404 should not recover");
  assertEquals(
    updates[0].values.recovery_status,
    "pending",
    "404 should stay blocked for retry/manual review",
  );
  assertEquals(
    updates[0].values.error_code,
    "TOSS_PAYMENT_NOT_FOUND_UNCONFIRMED",
    "404 should not be confirmed safe",
  );
  assert(
    updates[0].values.recovery_status !== "failed",
    "404 should not be terminal failed",
  );
  assertEquals(result.retryable, true, "404 remains retryable/blocking");
});

Deno.test("lookup_required validation mismatch blocks recovery and does not retry a charge", async () => {
  const { admin, rpcCalls, updates } = createMockAdmin();

  const result = await processReconciliationAttempt(admin, baseAttempt(), {
    tossSecret: "test_secret",
    fetchImpl: async () =>
      new Response(
        JSON.stringify({
          paymentKey: "payment_wrong_amount",
          orderId: "toss_renew_attempt_1",
          status: "DONE",
          totalAmount: 5000,
        }),
        { status: 200 },
      ),
    now: () => new Date("2026-01-01T00:10:00.000Z"),
  });

  assertEquals(rpcCalls.length, 0, "validation failure should not recover");
  assertEquals(
    updates[0].values.recovery_status,
    "pending",
    "validation failure should stay blocked",
  );
  assertEquals(
    updates[0].values.error_code,
    "TOSS_PAYMENT_VALIDATION_FAILED",
    "validation error should be explicit",
  );
  assertEquals(
    result.retryable,
    false,
    "validation mismatch is not auto-retryable",
  );
});
