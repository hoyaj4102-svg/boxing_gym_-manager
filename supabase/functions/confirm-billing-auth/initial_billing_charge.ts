import {
  lookupTossPaymentByOrderId,
  settleRecurringBillingCharge,
  type BillingSettlementResult,
  type OrderChargeGuard,
} from "../_shared/billing_order_reconciliation.ts";
import { chargeTossBilling } from "./charge_outcome.ts";

export async function settleInitialBillingCharge(input: {
  orderId: string;
  amountKrw: number;
  billingKey: string;
  authorization: string;
  customerKey: string;
  orderName: string;
  idempotencyKey: string;
  tossSecret: string;
  customerEmail?: string;
  customerName?: string;
  fetchImpl?: typeof fetch;
  guard?: OrderChargeGuard;
  lookupBeforePost?: boolean;
}): Promise<BillingSettlementResult> {
  const fetchImpl = input.fetchImpl ?? fetch;
  return await settleRecurringBillingCharge({
    orderId: input.orderId,
    amountKrw: input.amountKrw,
    guard: input.guard,
    lookupBeforePost: input.lookupBeforePost,
    charge: () =>
      chargeTossBilling({
        billingKey: input.billingKey,
        authorization: input.authorization,
        idempotencyKey: input.idempotencyKey,
        body: {
          customerKey: input.customerKey,
          amount: input.amountKrw,
          orderId: input.orderId,
          orderName: input.orderName,
          ...(input.customerEmail ? { customerEmail: input.customerEmail } : {}),
          ...(input.customerName ? { customerName: input.customerName } : {}),
        },
        fetchImpl,
      }),
    lookupOrder: () =>
      lookupTossPaymentByOrderId(input.orderId, input.tossSecret, fetchImpl),
  });
}
