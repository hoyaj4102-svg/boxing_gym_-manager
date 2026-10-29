import {
  expectedTossMerchantId,
  isDuplicateWebhookTerminal,
  TOSS_MID_CONFIG_ERROR,
  validateTossPaymentForAttempt,
} from "./merchant_validation.ts";

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

const attempt = {
  order_id: "toss_renew_attempt_1",
  amount_krw: 10000,
};

function donePayment(overrides: Record<string, unknown> = {}) {
  return {
    paymentKey: "payment_1",
    orderId: "toss_renew_attempt_1",
    status: "DONE",
    totalAmount: 10000,
    mId: "tosspayments_mid_1",
    ...overrides,
  };
}

Deno.test("matching Toss MID passes merchant validation", () => {
  const validation = validateTossPaymentForAttempt(
    attempt,
    "toss_renew_attempt_1",
    donePayment(),
    "tosspayments_mid_1",
  );

  assertEquals(validation.ok, true, "matching mId should pass");
  assertEquals(validation.midCheck, "checked", "MID check should be explicit");
  assertEquals(
    validation.failures,
    [],
    "matching payment should have no failures",
  );
});

Deno.test("mismatched Toss MID fails merchant validation", () => {
  const validation = validateTossPaymentForAttempt(
    attempt,
    "toss_renew_attempt_1",
    donePayment({ mId: "other_mid" }),
    "tosspayments_mid_1",
  );

  assertEquals(validation.ok, false, "mismatched mId should fail");
  assert(
    validation.failures.includes("mId mismatch"),
    "mismatched mId should be reported",
  );
});

Deno.test("missing Toss MID in verified payment response fails merchant validation", () => {
  const { mId: _mId, ...payment } = donePayment();

  const validation = validateTossPaymentForAttempt(
    attempt,
    "toss_renew_attempt_1",
    payment,
    "tosspayments_mid_1",
  );

  assertEquals(validation.ok, false, "missing mId should fail");
  assert(
    validation.failures.includes("mId missing"),
    "missing mId should be reported",
  );
});

Deno.test("missing expected Toss MID configuration fails closed", () => {
  const expectedMid = expectedTossMerchantId({ get: () => undefined });
  const validation = validateTossPaymentForAttempt(
    attempt,
    "toss_renew_attempt_1",
    donePayment(),
    expectedMid,
  );

  assertEquals(expectedMid, "", "missing config should resolve to empty MID");
  assertEquals(validation.ok, false, "missing expected MID should fail");
  assert(
    validation.failures.includes(TOSS_MID_CONFIG_ERROR),
    "missing expected MID should be reported",
  );
});

Deno.test("TOSS_MID takes precedence over TOSS_MERCHANT_ID", () => {
  const expectedMid = expectedTossMerchantId({
    get: (name: string) =>
      name === "TOSS_MID"
        ? "mid_from_toss_mid"
        : name === "TOSS_MERCHANT_ID"
        ? "mid_from_merchant_id"
        : undefined,
  });

  assertEquals(
    expectedMid,
    "mid_from_toss_mid",
    "TOSS_MID should be preferred",
  );
});

Deno.test("duplicate webhook terminal statuses are not reprocessed", () => {
  assertEquals(
    isDuplicateWebhookTerminal("processed"),
    true,
    "processed duplicates should short-circuit",
  );
  assertEquals(
    isDuplicateWebhookTerminal("validation_failed"),
    true,
    "validation_failed duplicates should short-circuit",
  );
  assertEquals(
    isDuplicateWebhookTerminal("received"),
    false,
    "received duplicates can be retried",
  );
  assertEquals(
    isDuplicateWebhookTerminal("processing"),
    false,
    "processing duplicates can be retried",
  );
  assertEquals(
    isDuplicateWebhookTerminal("retryable_error"),
    false,
    "retryable_error duplicates can be retried",
  );
});

Deno.test("validation failure blocks subscription activation decision", () => {
  const validation = validateTossPaymentForAttempt(
    attempt,
    "toss_renew_attempt_1",
    donePayment({ mId: "other_mid" }),
    "tosspayments_mid_1",
  );

  assertEquals(validation.ok, false, "validation should fail");
  assert(
    validation.failures.includes("mId mismatch"),
    "activation must not proceed on validation failure",
  );
});
