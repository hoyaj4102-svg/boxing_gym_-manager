import {
  handleCreateCheckoutRequest,
  LEGACY_CHECKOUT_DISABLED,
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
  return new Request("https://example.test/functions/v1/create-checkout", {
    method,
    headers: {
      Authorization: "Bearer test-token",
      "Content-Type": "application/json",
    },
    body,
  });
}

Deno.test("OPTIONS returns CORS response without authentication", async () => {
  let authCalls = 0;
  const response = await handleCreateCheckoutRequest(request("OPTIONS"), {
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

Deno.test("non-POST methods still return 405 without authentication", async () => {
  let authCalls = 0;
  const response = await handleCreateCheckoutRequest(request("GET"), {
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
  const response = await handleCreateCheckoutRequest(
    request("POST", JSON.stringify({ provider: "toss", interval: "yearly" })),
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

Deno.test("authenticated legacy checkout requests return 410", async () => {
  const cases = [
    { provider: "toss", interval: "monthly" },
    { provider: "toss", interval: "yearly" },
    { provider: "stripe", interval: "monthly" },
    { provider: "stripe", interval: "yearly" },
  ];

  for (const checkoutBody of cases) {
    let authCalls = 0;
    const response = await handleCreateCheckoutRequest(
      request("POST", JSON.stringify(checkoutBody)),
      {
        requireUser: async () => {
          authCalls += 1;
          return { user: { id: "user_1" } };
        },
      },
    );

    assertEquals(response.status, 410, "legacy checkout should be disabled");
    assertEquals(authCalls, 1, "authenticated POST should authenticate once");
    const payload = await response.json();
    assertEquals(
      payload.error,
      LEGACY_CHECKOUT_DISABLED,
      "disabled response should be machine-readable",
    );
  }
});

Deno.test("disabled checkout does not parse payload or create a session", async () => {
  const req = request("POST", "{not valid json");
  const response = await handleCreateCheckoutRequest(req, {
    requireUser: async () => ({ user: { id: "user_1" } }),
  });

  assertEquals(
    response.status,
    410,
    "invalid payload should still be disabled",
  );
  assertEquals(req.bodyUsed, false, "disabled checkout should not read body");
  const payload = await response.json();
  assertEquals(
    payload.error,
    LEGACY_CHECKOUT_DISABLED,
    "disabled response should not depend on checkout payload",
  );
});
