const HOUR_MS = 60 * 60 * 1000;
const RETRY_OFFSETS_HOURS = [24, 72, 120];
const GRACE_HOURS = 24 * 7;

export type PaymentFailurePlan = {
  state: "past_due" | "grace_expired";
  failureCount: number;
  firstFailedAt: string;
  graceUntil: string;
  nextRetryAt: string | null;
  cardReregistrationRequired: true;
  accessExtended: false;
  email: "disabled";
  sms: "disabled";
  inApp: true;
};

// Operational draft, not a statutory period. Access is not extended: the
// existing Pro check still treats past_due as no Pro access.
export function planPaymentFailure(input: {
  firstFailedAt: string;
  failedAt: string;
  failureCount: number;
}): PaymentFailurePlan {
  const first = new Date(input.firstFailedAt).getTime();
  const failed = new Date(input.failedAt).getTime();
  if (!Number.isInteger(input.failureCount) || input.failureCount < 1) {
    throw new Error("INVALID_FAILURE_COUNT");
  }
  if (!Number.isFinite(first) || !Number.isFinite(failed)) {
    throw new Error("INVALID_FAILURE_TIME");
  }

  const graceUntilMs = first + GRACE_HOURS * HOUR_MS;
  const offset = RETRY_OFFSETS_HOURS[input.failureCount - 1];
  const candidate = offset == null ? null : first + offset * HOUR_MS;
  const nextRetryAt = candidate != null && candidate <= graceUntilMs
    ? new Date(candidate).toISOString()
    : null;
  const state = failed >= graceUntilMs || nextRetryAt == null && input.failureCount >= 4
    ? "grace_expired"
    : "past_due";

  return {
    state,
    failureCount: input.failureCount,
    firstFailedAt: new Date(first).toISOString(),
    graceUntil: new Date(graceUntilMs).toISOString(),
    nextRetryAt,
    cardReregistrationRequired: true,
    accessExtended: false,
    email: "disabled",
    sms: "disabled",
    inApp: true,
  };
}
