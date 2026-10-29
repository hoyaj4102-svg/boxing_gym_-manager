import {
  handleConfirmTossPaymentRequest,
  LEGACY_TOSS_CONFIRM_DISABLED,
} from "./handler.ts";

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

function request(method: string, body?: string) {
  return new Request(
    "https://example.test/functions/v1/confirm-toss-payment",
    {
      method,
      headers: {
        Authorization: "Bearer test-token",
        "Content-Type": "application/json",
      },
      body,
    },
  );
}

Deno.test("OPTIONS returns CORS response without authentication", async () => {
  let authCalls = 0;
  const response = await handleConfirmTossPaymentRequest(request("OPTIONS"), {
    requireUser: async () => {
      authCalls += 1;
      return {};
    },
  });

  assertEquals(response.status, 200, "OPTIONS should return ok");
  assertEquals(await response.text(), "ok", "OPTIONS body should be ok");
  assertEquals(authCalls, 0, "OPTIONS should not authenticate");
  assert(
    response.headers.get("Access-Control-Allow-Origin") === "*",
    "OPTIONS should keep CORS headers",
  );
});

Deno.test("non-POST methods return 405 without authentication", async () => {
  let authCalls = 0;
  const response = await handleConfirmTossPaymentRequest(request("GET"), {
    requireUser: async () => {
      authCalls += 1;
      return {};
    },
  });

  assertEquals(response.status, 405, "GET should be rejected");
  assertEquals(
    await response.text(),
    "Method not allowed",
    "GET should keep existing error body",
  );
  assertEquals(authCalls, 0, "GET should not authenticate");
});

Deno.test("unauthenticated POST still returns 401", async () => {
  let authCalls = 0;
  const response = await handleConfirmTossPaymentRequest(
    request(
      "POST",
      JSON.stringify({
        paymentKey: "payment_1",
        orderId: "legacy_order_1",
        amount: 10000,
      }),
    ),
    {
      requireUser: async () => {
        authCalls += 1;
        throw new Error("UNAUTHORIZED");
      },
    },
  );

  assertEquals(response.status, 401, "unauthenticated POST should be 401");
  assertEquals(await response.text(), "UNAUTHORIZED", "401 body should remain");
  assertEquals(authCalls, 1, "POST should authenticate once");
});

Deno.test("authenticated POST returns 410 with disabled error code", async () => {
  let authCalls = 0;
  const response = await handleConfirmTossPaymentRequest(
    request(
      "POST",
      JSON.stringify({
        paymentKey: "payment_1",
        orderId: "legacy_order_1",
        amount: 10000,
      }),
    ),
    {
      requireUser: async () => {
        authCalls += 1;
        return { user: { id: "user_1" } };
      },
    },
  );

  assertEquals(response.status, 410, "legacy confirm should be disabled");
  assertEquals(authCalls, 1, "authenticated POST should authenticate once");
  const payload = await response.json();
  assertEquals(
    payload.error,
    LEGACY_TOSS_CONFIRM_DISABLED,
    "disabled response should be machine-readable",
  );
});

Deno.test("malformed POST body still returns 410 without reading payload", async () => {
  const req = request("POST", "{not valid json");
  const response = await handleConfirmTossPaymentRequest(req, {
    requireUser: async () => ({ user: { id: "user_1" } }),
  });

  assertEquals(
    response.status,
    410,
    "invalid payload should still be disabled",
  );
  assertEquals(req.bodyUsed, false, "disabled confirm should not read body");
  const payload = await response.json();
  assertEquals(
    payload.error,
    LEGACY_TOSS_CONFIRM_DISABLED,
    "disabled response should not depend on payment payload",
  );
});

Deno.test("disabled confirm does not call Toss fetch", async () => {
  const originalFetch = globalThis.fetch;
  let fetchCalls = 0;
  globalThis.fetch = (() => {
    fetchCalls += 1;
    throw new Error("fetch should not be called");
  }) as typeof fetch;

  try {
    const response = await handleConfirmTossPaymentRequest(
      request(
        "POST",
        JSON.stringify({
          paymentKey: "payment_1",
          orderId: "legacy_order_1",
          amount: 10000,
        }),
      ),
      {
        requireUser: async () => ({ user: { id: "user_1" } }),
      },
    );

    assertEquals(response.status, 410, "legacy confirm should be disabled");
    assertEquals(fetchCalls, 0, "disabled confirm must not call Toss");
  } finally {
    globalThis.fetch = originalFetch;
  }
});
