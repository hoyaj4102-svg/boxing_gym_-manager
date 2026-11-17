import {
  chargeTossBilling,
  type TossBillingChargeOutcome,
} from "./toss_charge_outcome.ts";

const TOSS_LOOKUP_TIMEOUT_MS = 10000;

export const ORDER_NOT_FOUND_RETRY_CODE = "TOSS_ORDER_NOT_FOUND_RETRY_SAME_ORDER";
export const PAYMENT_VALIDATION_CODE = "TOSS_PAYMENT_VALIDATION_FAILED";

const DUPLICATE_ORDER_CODES = new Set([
  "ALREADY_PROCESSED_PAYMENT",
  "DUPLICATED_ORDER_ID",
  "DUPLICATE_ORDER_ID",
]);

const RECORDED_PAYMENT_STATUSES = new Set([
  "charge_succeeded",
  "activation_pending",
  "completed",
  "activation_failed",
  "recovery_pending",
]);

export type TossLookupResult =
  | { kind: "found"; payment: Record<string, unknown> }
  | { kind: "not_found"; status: number; payload: unknown }
  | {
    kind: "retryable_error";
    status?: number;
    message: string;
    payload?: unknown;
  };

export type BillingExpectation = {
  orderId: string;
  amountKrw: number;
};

export type BillingSettlement =
  | {
    kind: "paid";
    paymentKey: string;
    payload: Record<string, unknown>;
    source: "billing_response" | "order_lookup";
  }
  | {
    kind: "failed";
    code: string;
    message: string;
    payload: unknown;
  }
  | {
    kind: "retry_same_order";
    code: string;
    message: string;
    payload: unknown;
    priorCode: string | null;
  }
  | {
    kind: "needs_review";
    code: string;
    message: string;
    payload: unknown;
    priorCode: string | null;
  }
  | {
    kind: "pending";
    code: string;
    message: string;
    payload: unknown;
    priorCode: string | null;
  };

export type BillingSettlementResult = {
  settlement: BillingSettlement;
  providerPosts: number;
};

export type OrderChargeGuard = {
  claim(orderId: string): boolean;
};

export type AttemptSnapshot = {
  orderId: string;
  status: string;
  paymentKey: string | null;
};

export type AttemptPlan = {
  apply: boolean;
  chargeAgain: boolean;
  clearDispatch: boolean;
  overwritePaymentKey: boolean;
  status: string;
  paymentKey: string | null;
  recoveryStatus: string;
};

type ChargeClassification =
  | { action: "paid"; paymentKey: string; payload: Record<string, unknown> }
  | { action: "failed"; code: string; message: string; payload: unknown }
  | { action: "lookup"; code: string; message: string; payload: unknown };

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function tossAuthHeader(secret: string) {
  if (!secret) throw new Error("TOSS_SECRET_KEY is missing");
  return `Basic ${btoa(`${secret}:`)}`;
}

async function readJsonResponse(response: Response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
  }
}

export function createOrderChargeGuard(): OrderChargeGuard {
  const charged = new Set<string>();
  return {
    claim(orderId: string) {
      if (!orderId || charged.has(orderId)) return false;
      charged.add(orderId);
      return true;
    },
  };
}

export function isRecordedPayment(attempt: AttemptSnapshot) {
  return Boolean(attempt.paymentKey) &&
    RECORDED_PAYMENT_STATUSES.has(attempt.status);
}

export function assessDonePayment(
  expected: BillingExpectation,
  payment: Record<string, unknown>,
) {
  const paymentKey = typeof payment.paymentKey === "string"
    ? payment.paymentKey
    : "";
  const orderId = typeof payment.orderId === "string" ? payment.orderId : "";
  const status = typeof payment.status === "string" ? payment.status : "";
  const totalAmount = Number(payment.totalAmount);
  const failures: string[] = [];

  if (!paymentKey) failures.push("paymentKey missing");
  if (orderId !== expected.orderId) failures.push("orderId mismatch");
  if (
    !Number.isFinite(totalAmount) || totalAmount !== Number(expected.amountKrw)
  ) {
    failures.push("totalAmount mismatch");
  }
  if (status !== "DONE") failures.push(`status is ${status || "missing"}`);

  return {
    ok: failures.length === 0,
    paymentKey,
    failures,
  };
}

export function classifyBillingCharge(
  outcome: TossBillingChargeOutcome,
  expected: BillingExpectation,
): ChargeClassification {
  if (outcome.kind === "uncertain") {
    return {
      action: "lookup",
      code: outcome.code,
      message: outcome.message,
      payload: outcome.payload,
    };
  }

  if (outcome.kind === "rejected") {
    if (DUPLICATE_ORDER_CODES.has(outcome.code)) {
      return {
        action: "lookup",
        code: outcome.code,
        message: outcome.message,
        payload: outcome.payload,
      };
    }
    return {
      action: "failed",
      code: outcome.code,
      message: outcome.message,
      payload: outcome.payload,
    };
  }

  const payload = outcome.payload;
  const status = typeof payload.status === "string" ? payload.status : "";
  const responseOrderId = typeof payload.orderId === "string"
    ? payload.orderId
    : "";
  const totalAmount = payload.totalAmount;

  if (status !== "DONE") {
    return {
      action: "lookup",
      code: status ? "TOSS_CHARGE_STATUS_NOT_DONE" : "TOSS_CHARGE_STATUS_MISSING",
      message: status
        ? `Billing response status is ${status}`
        : "Billing response included paymentKey without status",
      payload,
    };
  }
  if (responseOrderId && responseOrderId !== expected.orderId) {
    return {
      action: "lookup",
      code: "TOSS_CHARGE_ORDER_MISMATCH",
      message: "Billing response orderId did not match the charged order",
      payload,
    };
  }
  if (
    totalAmount !== undefined && totalAmount !== null &&
    Number(totalAmount) !== Number(expected.amountKrw)
  ) {
    return {
      action: "lookup",
      code: "TOSS_CHARGE_AMOUNT_MISMATCH",
      message: "Billing response amount did not match the charged amount",
      payload,
    };
  }

  return {
    action: "paid",
    paymentKey: outcome.paymentKey,
    payload,
  };
}

export function classifyOrderLookup(
  lookup: TossLookupResult,
  expected: BillingExpectation,
  priorCode: string | null = null,
): BillingSettlement {
  if (lookup.kind === "retryable_error") {
    return {
      kind: "pending",
      code: lookup.status
        ? `TOSS_LOOKUP_${lookup.status}`
        : "TOSS_LOOKUP_RETRYABLE",
      message: lookup.message,
      payload: lookup.payload ?? null,
      priorCode,
    };
  }

  if (lookup.kind === "not_found") {
    return {
      kind: "retry_same_order",
      code: ORDER_NOT_FOUND_RETRY_CODE,
      message:
        "No Toss payment exists for this orderId. A later charge must reuse this orderId and must not create another one.",
      payload: lookup.payload,
      priorCode,
    };
  }

  const assessed = assessDonePayment(expected, lookup.payment);
  if (!assessed.ok) {
    return {
      kind: "needs_review",
      code: PAYMENT_VALIDATION_CODE,
      message: assessed.failures.join("; "),
      payload: lookup.payment,
      priorCode,
    };
  }

  return {
    kind: "paid",
    paymentKey: assessed.paymentKey,
    payload: lookup.payment,
    source: "order_lookup",
  };
}

export function planAttemptWrite(
  current: AttemptSnapshot,
  settlement: BillingSettlement,
): AttemptPlan {
  if (
    isRecordedPayment(current) && settlement.kind === "paid" &&
    settlement.paymentKey === current.paymentKey
  ) {
    return {
      apply: false,
      chargeAgain: false,
      clearDispatch: false,
      overwritePaymentKey: false,
      status: current.status,
      paymentKey: current.paymentKey,
      recoveryStatus: "none",
    };
  }

  if (isRecordedPayment(current)) {
    return {
      apply: true,
      chargeAgain: false,
      clearDispatch: false,
      overwritePaymentKey: false,
      status: current.status,
      paymentKey: current.paymentKey,
      recoveryStatus: "pending",
    };
  }

  if (settlement.kind === "paid") {
    return {
      apply: true,
      chargeAgain: false,
      clearDispatch: false,
      overwritePaymentKey: true,
      status: "activation_pending",
      paymentKey: settlement.paymentKey,
      recoveryStatus: "none",
    };
  }

  if (settlement.kind === "failed") {
    return {
      apply: true,
      chargeAgain: false,
      clearDispatch: false,
      overwritePaymentKey: false,
      status: "charge_failed",
      paymentKey: null,
      recoveryStatus: "none",
    };
  }

  if (settlement.kind === "retry_same_order") {
    return {
      apply: true,
      chargeAgain: true,
      clearDispatch: true,
      overwritePaymentKey: false,
      status: "initiated",
      paymentKey: null,
      recoveryStatus: "none",
    };
  }

  return {
    apply: true,
    chargeAgain: false,
    clearDispatch: false,
    overwritePaymentKey: false,
    status: "charge_failed",
    paymentKey: null,
    recoveryStatus: "pending",
  };
}

export async function lookupTossPaymentByOrderId(
  orderId: string,
  tossSecret: string,
  fetchImpl: typeof fetch = fetch,
): Promise<TossLookupResult> {
  const controller = new AbortController();
  const timeoutId = setTimeout(
    () => controller.abort(),
    TOSS_LOOKUP_TIMEOUT_MS,
  );

  try {
    const response = await fetchImpl(
      `https://api.tosspayments.com/v1/payments/orders/${
        encodeURIComponent(orderId)
      }`,
      {
        method: "GET",
        headers: {
          Authorization: tossAuthHeader(tossSecret),
        },
        signal: controller.signal,
      },
    );
    const payload = await readJsonResponse(response);

    if (
      response.ok && payload && typeof payload === "object" &&
      !Array.isArray(payload)
    ) {
      return { kind: "found", payment: payload as Record<string, unknown> };
    }

    if (response.status === 404) {
      return { kind: "not_found", status: response.status, payload };
    }

    return {
      kind: "retryable_error",
      status: response.status,
      message: `Unexpected Toss lookup response: ${response.status}`,
      payload,
    };
  } catch (error) {
    return {
      kind: "retryable_error",
      message: errorMessage(error),
    };
  } finally {
    clearTimeout(timeoutId);
  }
}

export async function settleRecurringBillingCharge(input: {
  orderId: string;
  amountKrw: number;
  charge: () => Promise<TossBillingChargeOutcome>;
  lookupOrder: () => Promise<TossLookupResult>;
  guard?: OrderChargeGuard;
  lookupBeforePost?: boolean;
}): Promise<BillingSettlementResult> {
  const guard = input.guard ?? createOrderChargeGuard();
  const expected = { orderId: input.orderId, amountKrw: input.amountKrw };

  if (input.lookupBeforePost) {
    const preview = classifyOrderLookup(await input.lookupOrder(), expected);
    if (preview.kind !== "retry_same_order") {
      return { providerPosts: 0, settlement: preview };
    }
  }

  if (!guard.claim(input.orderId)) {
    return {
      providerPosts: 0,
      settlement: classifyOrderLookup(await input.lookupOrder(), expected),
    };
  }

  const outcome = await input.charge();
  const classified = classifyBillingCharge(outcome, expected);
  if (classified.action === "paid") {
    return {
      providerPosts: 1,
      settlement: {
        kind: "paid",
        paymentKey: classified.paymentKey,
        payload: classified.payload,
        source: "billing_response",
      },
    };
  }
  if (classified.action === "failed") {
    return {
      providerPosts: 1,
      settlement: {
        kind: "failed",
        code: classified.code,
        message: classified.message,
        payload: classified.payload,
      },
    };
  }

  return {
    providerPosts: 1,
    settlement: classifyOrderLookup(
      await input.lookupOrder(),
      expected,
      classified.code,
    ),
  };
}

export async function reconcilePendingBillingOrder(input: {
  orderId: string;
  amountKrw: number;
  lookupOrder: () => Promise<TossLookupResult>;
}): Promise<BillingSettlementResult> {
  return {
    providerPosts: 0,
    settlement: classifyOrderLookup(
      await input.lookupOrder(),
      { orderId: input.orderId, amountKrw: input.amountKrw },
    ),
  };
}

export async function chargeAndSettleRecurringBilling(input: {
  orderId: string;
  amountKrw: number;
  billingKey: string;
  authorization: string;
  customerKey: string;
  orderName: string;
  idempotencyKey: string;
  tossSecret: string;
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
        },
        fetchImpl,
      }),
    lookupOrder: () =>
      lookupTossPaymentByOrderId(input.orderId, input.tossSecret, fetchImpl),
  });
}
