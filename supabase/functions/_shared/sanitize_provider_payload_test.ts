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
    orderId: "toss_renew_attempt_1",
    status: "DONE",
    totalAmount: 10000,
    billingKey: credential,
    billing_key: credential,
    authKey: "auth-value",
    cardNumber,
    card: {
      company: "Test Card",
      number: cardNumber,
    },
    customerKey: "customer_1",
    customerEmail: email,
    customerName: "Member Name",
    customerIdentityNumber: "900101-1234567",
    nested: [
      {
        secret: "secret-value",
        authorization: "Basic secret",
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
  assertEquals(sanitized.paymentKey, "payment_1", "payment reference stays");
  assertEquals(sanitized.orderId, "toss_renew_attempt_1", "order id stays");
  assertEquals(sanitized.totalAmount, 10000, "amount stays");
  assertEquals(sanitized.billingKeyIssued, true, "non-secret flag stays");
  assertEquals(sanitized.billingKey, REDACTED, "credential field is redacted");
  assertEquals(sanitized.card, REDACTED, "card object is redacted");
  assertEquals(sanitized.customerEmail, REDACTED, "customer email field is redacted");
  const nested = sanitized.nested as Array<Record<string, unknown>>;
  assertEquals(nested[0].secret, REDACTED, "nested secret is redacted");
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
