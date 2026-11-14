import { lookupTossReceiptByPaymentKey } from "../_shared/toss_receipt.ts";
import type { TossTestGuard } from "../_shared/toss_test_guard.ts";

export async function executeReceiptLookup(input: {
  guard: TossTestGuard;
  paymentKey: string;
  authorization: string;
  fetchImpl?: typeof fetch;
}) {
  if (!input.guard.allow) {
    return {
      providerCalls: 0,
      status: "blocked" as const,
      code: input.guard.code,
      receiptUrl: null,
    };
  }
  const lookedUp = await lookupTossReceiptByPaymentKey({
    paymentKey: input.paymentKey,
    authorization: input.authorization,
    fetchImpl: input.fetchImpl,
  });
  return {
    providerCalls: lookedUp.providerCalls,
    status: lookedUp.receiptUrl ? "found" as const : "unavailable" as const,
    code: lookedUp.code,
    receiptUrl: lookedUp.receiptUrl,
  };
}
