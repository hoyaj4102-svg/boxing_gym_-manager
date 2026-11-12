export const REDACTED = "[REDACTED]";

const SENSITIVE_KEYS = new Set([
  "authkey",
  "authorization",
  "billingkey",
  "card",
  "cardno",
  "cardnumber",
  "customeremail",
  "customeridentitynumber",
  "customerkey",
  "customermobilephone",
  "customername",
  "secret",
  "secretkey",
  "approvalno",
  "approvalnumber",
  "approveno",
  "checkout",
  "checkouturl",
  "lasttransactionkey",
  "merchantid",
  "mid",
  "paymentkey",
  "receipt",
  "receipturl",
  "transactionkey",
]);

const CARD_LIKE_VALUE = /^(?:\d[ -]?){13,19}$/;

function normalizedKey(key: string) {
  return key.replace(/[_\-\s]/g, "").toLowerCase();
}

export function sanitizeProviderPayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeProviderPayload);
  }

  if (typeof value === "string") {
    return CARD_LIKE_VALUE.test(value.trim()) ? REDACTED : value;
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        if (SENSITIVE_KEYS.has(normalizedKey(key))) {
          return [key, REDACTED];
        }
        return [key, sanitizeProviderPayload(entry)];
      }),
    );
  }

  return value;
}
