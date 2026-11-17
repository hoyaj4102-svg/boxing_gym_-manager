import {
  lookupTossPaymentByOrderId,
  settleRecurringBillingCharge,
  type BillingSettlement,
  type BillingSettlementResult,
} from "../_shared/billing_order_reconciliation.ts";
import { sanitizeProviderPayload } from "../_shared/sanitize_provider_payload.ts";
import { chargeTossBilling } from "../_shared/toss_charge_outcome.ts";
import { chargeIdempotencyKey } from "../_shared/toss_idempotency.ts";

export async function executeFailureRetryCharge(input: {
  orderId: string;
  amountKrw: number;
  customerKey: string;
  billingKey: string;
  authorization: string;
  tossSecret: string;
  fetchImpl?: typeof fetch;
}): Promise<BillingSettlementResult> {
  const fetchImpl = input.fetchImpl ?? fetch;
  return await settleRecurringBillingCharge({
    orderId: input.orderId,
    amountKrw: input.amountKrw,
    lookupBeforePost: true,
    charge: () =>
      chargeTossBilling({
        billingKey: input.billingKey,
        authorization: input.authorization,
        idempotencyKey: chargeIdempotencyKey(input.orderId),
        body: {
          customerKey: input.customerKey,
          amount: input.amountKrw,
          orderId: input.orderId,
          orderName: "re;member Pro 월간 자동결제 재시도",
        },
        fetchImpl,
      }),
    lookupOrder: () =>
      lookupTossPaymentByOrderId(input.orderId, input.tossSecret, fetchImpl),
  });
}

export function failureRetryAttemptUpdate(
  settlement: BillingSettlement,
): Record<string, unknown> {
  if (settlement.kind === "paid") {
    return {
      status: "activation_pending",
      activation_status: "pending",
      recovery_status: "none",
      payment_key: settlement.paymentKey,
      error_code: null,
      error_message: null,
      provider_response: sanitizeProviderPayload(settlement.payload),
    };
  }
  if (settlement.kind === "failed") {
    return {
      status: "charge_failed",
      activation_status: "not_started",
      recovery_status: "none",
      error_code: settlement.code,
      error_message: settlement.message,
      provider_response: sanitizeProviderPayload({
        mode: "failure_retry_rejected",
        charge: settlement.payload,
      }),
    };
  }
  if (settlement.kind === "retry_same_order") {
    return {
      status: "initiated",
      activation_status: "not_started",
      recovery_status: "none",
      error_code: settlement.code,
      error_message: settlement.message,
      provider_response: sanitizeProviderPayload({
        mode: "failure_retry_same_order",
        lookup: settlement.payload,
      }),
    };
  }
  return {
    status: "charge_failed",
    activation_status: "not_started",
    recovery_status: "pending",
    error_code: settlement.code,
    error_message: settlement.message,
    provider_response: sanitizeProviderPayload({
      mode: settlement.kind === "pending"
        ? "failure_retry_pending"
        : "failure_retry_needs_review",
      lookup: settlement.payload,
    }),
  };
}
