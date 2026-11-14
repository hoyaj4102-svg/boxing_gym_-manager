export const DRAFT_REFUND_POLICY_VERSION = "draft-2026-11-12";
const SEVEN_DAYS_MS = 7 * 24 * 60 * 60 * 1000;

export type RefundReason = "customer_request" | "duplicate_charge" | "system_error";

export type RefundDecision = {
  allowed: boolean;
  code: string;
  refundAmountKrw: number;
  partial: boolean;
};

function deny(code: string): RefundDecision {
  return { allowed: false, code, refundAmountKrw: 0, partial: false };
}

function allow(amountKrw: number, code: string): RefundDecision {
  return {
    allowed: true,
    code,
    refundAmountKrw: amountKrw,
    partial: false,
  };
}

// Draft policy from the pricing screen: full refund within 7 days unless the
// service was normally used; no partial refund of the remaining term; full
// refund for a duplicate charge or system error. "Normally used" is not inferred.
export function evaluateDraftRefund(input: {
  paidAt: string;
  now: string;
  amountKrw: number;
  requestedAmountKrw: number;
  reason: string;
  normallyUsed: boolean | null;
}): RefundDecision {
  if (!Number.isInteger(input.amountKrw) || input.amountKrw <= 0) {
    return deny("INVALID_AMOUNT");
  }
  if (
    !Number.isInteger(input.requestedAmountKrw) ||
    input.requestedAmountKrw <= 0 ||
    input.requestedAmountKrw > input.amountKrw
  ) {
    return deny("INVALID_REQUESTED_AMOUNT");
  }
  if (input.requestedAmountKrw !== input.amountKrw) {
    return deny("PARTIAL_REFUND_NOT_IN_DRAFT_POLICY");
  }

  if (input.reason === "duplicate_charge" || input.reason === "system_error") {
    return allow(input.amountKrw, "FULL_REFUND_DUPLICATE_OR_SYSTEM_ERROR");
  }
  if (input.reason !== "customer_request") return deny("UNKNOWN_REASON");

  const paid = new Date(input.paidAt).getTime();
  const now = new Date(input.now).getTime();
  if (!Number.isFinite(paid) || !Number.isFinite(now) || now < paid) {
    return deny("INVALID_TIME");
  }
  if (now - paid > SEVEN_DAYS_MS) return deny("REFUND_WINDOW_EXPIRED");
  if (input.normallyUsed === true) return deny("NORMAL_USE_LIMIT");
  if (input.normallyUsed !== false) return deny("NORMAL_USE_UNCONFIRMED");
  return allow(input.amountKrw, "FULL_REFUND_WITHIN_7_DAYS");
}
