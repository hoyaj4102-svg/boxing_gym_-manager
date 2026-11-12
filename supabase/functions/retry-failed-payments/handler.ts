import { chargeTossBilling } from "../_shared/toss_charge_outcome.ts";
import { chargeIdempotencyKey } from "../_shared/toss_idempotency.ts";

export async function executeFailureRetryCharge(input: {
  orderId: string;
  amountKrw: number;
  customerKey: string;
  billingKey: string;
  authorization: string;
  fetchImpl?: typeof fetch;
}) {
  return await chargeTossBilling({
    billingKey: input.billingKey,
    authorization: input.authorization,
    idempotencyKey: chargeIdempotencyKey(input.orderId),
    body: {
      customerKey: input.customerKey,
      amount: input.amountKrw,
      orderId: input.orderId,
      orderName: "re;member Pro 월간 자동결제 재시도",
    },
    fetchImpl: input.fetchImpl,
  });
}
