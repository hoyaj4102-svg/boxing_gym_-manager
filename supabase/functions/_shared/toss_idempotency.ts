const IDEMPOTENCY_KEY = /^[A-Za-z0-9_-]{8,300}$/;

function scopedKey(prefix: "charge" | "cancel", rawId: string): string {
  const safe = String(rawId || "").replace(/[^A-Za-z0-9_-]/g, "");
  const key = `${prefix}_${safe}`;
  if (!IDEMPOTENCY_KEY.test(key)) {
    throw new Error("IDEMPOTENCY_KEY_INVALID");
  }
  return key;
}

export function chargeIdempotencyKey(orderId: string): string {
  return scopedKey("charge", orderId);
}

export function cancelIdempotencyKey(refundRequestId: string): string {
  return scopedKey("cancel", refundRequestId);
}
