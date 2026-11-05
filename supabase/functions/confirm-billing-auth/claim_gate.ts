export function alreadyCompletedIsCurrent(
  claim: { current_period_end?: unknown },
  nowMs = Date.now(),
) {
  const periodEnd = typeof claim.current_period_end === "string"
    ? claim.current_period_end
    : "";
  const periodEndMs = Date.parse(periodEnd);
  return Number.isFinite(periodEndMs) && periodEndMs > nowMs;
}
