import { cancelIdempotencyKey } from "../_shared/toss_idempotency.ts";
import type { RefundDecision } from "../_shared/refund_policy.ts";
import { cancelTossPayment } from "../_shared/toss_cancel.ts";
import type { TossTestGuard } from "../_shared/toss_test_guard.ts";

export async function executeRefund(input: {
  decision: RefundDecision;
  guard: TossTestGuard;
  paymentKey: string;
  refundRequestId: string;
  cancelReason: string;
  authorization: string;
  fetchImpl?: typeof fetch;
}) {
  if (!input.decision.allowed) {
    return { providerCalls: 0, status: "denied" as const, code: input.decision.code };
  }
  if (!input.guard.allow) {
    return { providerCalls: 0, status: "blocked" as const, code: input.guard.code };
  }
  if (!input.paymentKey) {
    return { providerCalls: 0, status: "failed" as const, code: "PAYMENT_KEY_MISSING" };
  }

  const outcome = await cancelTossPayment({
    paymentKey: input.paymentKey,
    cancelReason: input.cancelReason,
    cancelAmountKrw: input.decision.partial ? input.decision.refundAmountKrw : null,
    idempotencyKey: cancelIdempotencyKey(input.refundRequestId),
    authorization: input.authorization,
    fetchImpl: input.fetchImpl,
  });

  if (outcome.kind === "success") {
    return { providerCalls: 1, status: "succeeded" as const, code: "CANCEL_ACCEPTED" };
  }
  return {
    providerCalls: 1,
    status: outcome.kind === "uncertain" ? "uncertain" as const : "failed" as const,
    code: outcome.code,
  };
}
