import { REDACTED, sanitizeProviderPayload } from "./sanitize_provider_payload.ts";

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

const credential = "stored-credential";
const cardNumber = "4111111111111111";
const email = "member@example.test";

Deno.test("sanitize removes credentials, card numbers, and customer identifiers", () => {
  const sanitized = sanitizeProviderPayload({
    paymentKey: "payment_1",
    lastTransactionKey: "transaction_1",
    transactionKey: "transaction_2",
    orderId: "toss_renew_attempt_1",
    status: "DONE",
    totalAmount: 10000,
    approvedAt: "2026-01-15T00:00:00Z",
    method: "card",
    mId: "synthetic-mid",
    merchantId: "synthetic-merchant",
    approveNo: "synthetic-approval",
    approvalNumber: "synthetic-approval-number",
    receipt: { url: "https://example.test/receipt/synthetic" },
    checkout: { url: "https://example.test/checkout/synthetic" },
    receiptUrl: "https://example.test/receipt/flat",
    checkoutUrl: "https://example.test/checkout/flat",
    billingKey: credential,
    billing_key: credential,
    authKey: "auth-value",
    cardNumber,
    card: {
      company: "Test Card",
      number: cardNumber,
      approveNo: "synthetic-approval-card",
    },
    customerKey: "customer_1",
    customerEmail: email,
    customerName: "Member Name",
    customerIdentityNumber: "900101-1234567",
    nested: [
      {
        secret: "secret-value",
        authorization: "Basic secret",
        payment_key: "payment_nested",
        note: cardNumber,
      },
    ],
    billingKeyIssued: true,
  }) as Record<string, unknown>;

  const serialized = JSON.stringify(sanitized);
  assert(!serialized.includes(credential), "credential value must be removed");
  assert(!serialized.includes(cardNumber), "card number must be removed");
  assert(!serialized.includes(email), "customer email must be removed");
  assert(!serialized.includes("customer_1"), "customer key must be removed");
  assert(!serialized.includes("Member Name"), "customer name must be removed");
  assert(!serialized.includes("secret-value"), "secret value must be removed");
  assert(!serialized.includes("Basic secret"), "authorization value must be removed");
  assert(!serialized.includes("payment_1"), "payment key must be removed");
  assert(!serialized.includes("payment_nested"), "nested payment key must be removed");
  assert(!serialized.includes("transaction_1"), "transaction key must be removed");
  assert(!serialized.includes("transaction_2"), "alternate transaction key must be removed");
  assert(!serialized.includes("synthetic-mid"), "merchant id must be removed");
  assert(!serialized.includes("synthetic-merchant"), "merchant id alias must be removed");
  assert(!serialized.includes("synthetic-approval"), "approval number must be removed");
  assert(!serialized.includes("example.test/receipt"), "receipt URL must be removed");
  assert(!serialized.includes("example.test/checkout"), "checkout URL must be removed");
  assertEquals(sanitized.paymentKey, REDACTED, "payment key is redacted");
  assertEquals(sanitized.lastTransactionKey, REDACTED, "transaction key is redacted");
  assertEquals(sanitized.mId, REDACTED, "merchant id is redacted");
  assertEquals(sanitized.approveNo, REDACTED, "approval number is redacted");
  assertEquals(sanitized.receipt, REDACTED, "receipt object is redacted");
  assertEquals(sanitized.checkout, REDACTED, "checkout object is redacted");
  assertEquals(sanitized.orderId, "toss_renew_attempt_1", "order id stays");
  assertEquals(sanitized.status, "DONE", "status stays");
  assertEquals(sanitized.totalAmount, 10000, "amount stays");
  assertEquals(sanitized.approvedAt, "2026-01-15T00:00:00Z", "approval time stays");
  assertEquals(sanitized.method, "card", "payment method stays");
  assertEquals(sanitized.billingKeyIssued, true, "non-secret flag stays");
  assertEquals(sanitized.billingKey, REDACTED, "credential field is redacted");
  assertEquals(sanitized.card, REDACTED, "card object is redacted");
  assertEquals(sanitized.customerEmail, REDACTED, "customer email field is redacted");
  const nested = sanitized.nested as Array<Record<string, unknown>>;
  assertEquals(nested[0].secret, REDACTED, "nested secret is redacted");
  assertEquals(nested[0].payment_key, REDACTED, "nested payment key is redacted");
  assertEquals(nested[0].note, REDACTED, "card-like text is redacted");
});

Deno.test("sanitize keeps ordinary short numbers and empty values", () => {
  assertEquals(
    sanitizeProviderPayload({
      amount: "10000",
      phone: "01012345678",
      empty: "",
      list: [],
      nothing: null,
    }),
    {
      amount: "10000",
      phone: "01012345678",
      empty: "",
      list: [],
      nothing: null,
    },
    "non-sensitive values stay unchanged",
  );
});
