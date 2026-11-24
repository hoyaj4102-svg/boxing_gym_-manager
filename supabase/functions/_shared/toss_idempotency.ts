const IDEMPOTENCY_KEY = /^[A-Za-z0-9_-]{8,300}$/;

// Billing approval only. A cancel key is intentionally not defined here.
export function chargeIdempotencyKey(orderId: string): string {
  const safe = String(orderId || "").replace(/[^A-Za-z0-9_-]/g, "");
  const key = `charge_${safe}`;
  if (!IDEMPOTENCY_KEY.test(key)) {
    throw new Error("IDEMPOTENCY_KEY_INVALID");
  }
  return key;
}
