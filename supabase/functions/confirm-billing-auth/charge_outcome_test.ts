import { chargeTossBilling } from "./charge_outcome.ts";

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

function baseRequest(fetchImpl: typeof fetch) {
  return {
    billingKey: "billing_key_1",
    authorization: "Basic test",
    body: {
      customerKey: "customer_1",
      amount: 10000,
      orderId: "toss_bill_attempt_1",
      orderName: "re;member Pro 월간 구독",
    },
    fetchImpl,
  };
}

function idempotencyKey(init: RequestInit | undefined) {
  return new Headers(init?.headers).get("Idempotency-Key");
}

Deno.test("successful billing charge returns paymentKey", async () => {
  const methods: string[] = [];
  const keys: Array<string | null> = [];
  const result = await chargeTossBilling(baseRequest(async (_input, init) => {
    methods.push(String(init?.method || "GET"));
    keys.push(idempotencyKey(init));
    return new Response(
      JSON.stringify({
        paymentKey: "payment_1",
        orderId: "toss_bill_attempt_1",
        status: "DONE",
        totalAmount: 10000,
      }),
      { status: 200 },
    );
  }));

  assertEquals(methods, ["POST"], "charge should use one POST");
  assertEquals(
    keys,
    ["charge_toss_bill_attempt_1"],
    "approval should send the order attempt key",
  );
  assertEquals(result.kind, "success", "successful charge should be success");
  assertEquals(
    result.kind === "success" ? result.paymentKey : null,
    "payment_1",
    "paymentKey should be returned",
  );
});

Deno.test("network failure is uncertain and not a rejected charge", async () => {
  let calls = 0;
  const keys: Array<string | null> = [];
  const result = await chargeTossBilling(baseRequest(async (_input, init) => {
    calls += 1;
    keys.push(idempotencyKey(init));
    throw new TypeError("network dropped after approval");
  }));

  assertEquals(calls, 1, "charge helper must not retry POST");
  assertEquals(
    keys,
    ["charge_toss_bill_attempt_1"],
    "a dropped approval still uses the attempt key",
  );
  assertEquals(result.kind, "uncertain", "network failure should be uncertain");
  assert(
    result.kind !== "rejected",
    "network failure must not be classified as rejected",
  );
});

Deno.test("5xx HTTP charge response is uncertain", async () => {
  const result = await chargeTossBilling(
    baseRequest(async () =>
      new Response(
        JSON.stringify({ code: "SERVER_ERROR", message: "temporary" }),
        {
          status: 500,
        },
      )
    ),
  );

  assertEquals(result.kind, "uncertain", "5xx should be uncertain");
  assertEquals(
    result.kind === "uncertain" ? result.code : null,
    "TOSS_CHARGE_HTTP_UNCERTAIN",
    "5xx should use uncertain error code",
  );
});

Deno.test("clear 4xx charge rejection is rejected", async () => {
  const result = await chargeTossBilling(
    baseRequest(async () =>
      new Response(
        JSON.stringify({ code: "REJECT_CARD_COMPANY", message: "declined" }),
        {
          status: 400,
        },
      )
    ),
  );

  assertEquals(result.kind, "rejected", "clear 4xx should be rejected");
  assertEquals(
    result.kind === "rejected" ? result.code : null,
    "REJECT_CARD_COMPANY",
    "Toss rejection code should be preserved",
  );
});

Deno.test("successful HTTP response with malformed body is uncertain", async () => {
  const result = await chargeTossBilling(
    baseRequest(async () => new Response("{", { status: 200 })),
  );

  assertEquals(
    result.kind,
    "uncertain",
    "malformed 200 response should be uncertain",
  );
});

Deno.test("successful HTTP response without paymentKey is uncertain", async () => {
  const result = await chargeTossBilling(baseRequest(async () =>
    new Response(
      JSON.stringify({
        orderId: "toss_bill_attempt_1",
        status: "DONE",
        totalAmount: 10000,
      }),
      { status: 200 },
    )
  ));

  assertEquals(
    result.kind,
    "uncertain",
    "missing paymentKey should wait for order lookup recovery",
  );
  assertEquals(
    result.kind === "uncertain" ? result.code : null,
    "TOSS_CHARGE_PAYMENT_KEY_MISSING_UNCERTAIN",
    "missing paymentKey should have a distinct uncertain code",
  );
});

Deno.test("missing orderId does not call Toss", async () => {
  let calls = 0;
  const request = baseRequest(async () => {
    calls += 1;
    return new Response("{}", { status: 200 });
  });
  const result = await chargeTossBilling({
    ...request,
    body: { amount: 10000 },
  });

  assertEquals(calls, 0, "invalid attempt key must not approve");
  assertEquals(result.kind, "uncertain", "missing orderId is uncertain");
  assertEquals(
    result.kind === "uncertain" ? result.code : null,
    "IDEMPOTENCY_KEY_INVALID",
    "missing orderId should not be sent",
  );
});

Deno.test("a different explicit idempotency key does not call Toss", async () => {
  let calls = 0;
  const request = baseRequest(async () => {
    calls += 1;
    return new Response("{}", { status: 200 });
  });
  const result = await chargeTossBilling({
    ...request,
    idempotencyKey: "charge_other_attempt",
  });

  assertEquals(calls, 0, "mismatched key must not approve");
  assertEquals(
    result.kind === "uncertain" ? result.code : null,
    "IDEMPOTENCY_KEY_MISMATCH",
    "explicit key must match the attempt order id",
  );
});
