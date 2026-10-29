export const TOSS_MID_CONFIG_ERROR = "TOSS_MID_NOT_CONFIGURED";

export type PaymentAttemptForValidation = {
  order_id: string;
  amount_krw: number;
};

export type TossPaymentValidationResult = {
  ok: boolean;
  paymentKey: string;
  status: string;
  failures: string[];
  midCheck: "checked";
};

export function expectedTossMerchantId(env: {
  get(name: string): string | undefined;
}) {
  return (env.get("TOSS_MID") || env.get("TOSS_MERCHANT_ID") || "").trim();
}

export function isDuplicateWebhookTerminal(processingStatus: string) {
  return !["received", "processing", "retryable_error"].includes(
    processingStatus,
  );
}

export function validateTossPaymentForAttempt(
  attempt: PaymentAttemptForValidation,
  webhookOrderId: string,
  payment: Record<string, unknown>,
  expectedMid: string,
): TossPaymentValidationResult {
  const paymentKey = typeof payment.paymentKey === "string"
    ? payment.paymentKey
    : "";
  const orderId = typeof payment.orderId === "string" ? payment.orderId : "";
  const status = typeof payment.status === "string" ? payment.status : "";
  const totalAmount = Number(payment.totalAmount);
  const paymentMid = typeof payment.mId === "string" ? payment.mId : "";

  const failures: string[] = [];
  if (orderId !== webhookOrderId) failures.push("queried orderId mismatch");
  if (attempt.order_id !== orderId) {
    failures.push("payment_attempt orderId mismatch");
  }
  if (
    !Number.isFinite(totalAmount) || totalAmount !== Number(attempt.amount_krw)
  ) {
    failures.push("amount mismatch");
  }
  if (!paymentKey) failures.push("paymentKey missing");
  if (!expectedMid) failures.push(TOSS_MID_CONFIG_ERROR);
  if (!paymentMid) failures.push("mId missing");
  if (expectedMid && paymentMid && paymentMid !== expectedMid) {
    failures.push("mId mismatch");
  }

  return {
    ok: failures.length === 0,
    paymentKey,
    status,
    failures,
    midCheck: "checked",
  };
}
