import {
  assessDonePayment,
  classifyOrderLookup,
  isRecordedPayment,
  lookupTossPaymentByOrderId,
  ORDER_NOT_FOUND_RETRY_CODE,
  type TossLookupResult,
} from "../_shared/billing_order_reconciliation.ts";
import { sanitizeProviderPayload } from "../_shared/sanitize_provider_payload.ts";

export { lookupTossPaymentByOrderId };

export type ReconciliationAction = "lookup_required" | "recovery_only";

export type ReconciliationAttempt = {
  id: string;
  gym_id: string;
  order_id: string;
  amount_krw: number;
  customer_key: string | null;
  billing_key_ref: string | null;
  status: string;
  activation_status: string;
  recovery_status: string;
  payment_key: string | null;
  reconciliation_action: ReconciliationAction;
  target_period_start: string | null;
  target_period_end: string | null;
  created_at: string;
  updated_at: string;
};

type UpdateQuery = {
  eq(
    column: string,
    value: string,
  ): PromiseLike<{ error: { message: string } | null }>;
};

export type AdminClientLike = {
  from(table: string): {
    update(values: Record<string, unknown>): UpdateQuery;
  };
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<
    { data: unknown; error: { code?: string; message: string } | null }
  >;
};

type ProcessOptions = {
  tossSecret: string;
  fetchImpl?: typeof fetch;
  now?: () => Date;
};

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

export function validateDonePayment(
  attempt: ReconciliationAttempt,
  payment: Record<string, unknown>,
) {
  return assessDonePayment(
    { orderId: attempt.order_id, amountKrw: Number(attempt.amount_krw) },
    payment,
  );
}

async function updateAttempt(
  admin: AdminClientLike,
  attemptId: string,
  values: Record<string, unknown>,
) {
  const { error } = await admin
    .from("payment_attempts")
    .update(values)
    .eq("id", attemptId);

  if (error) {
    throw new Error(`PAYMENT_ATTEMPT_UPDATE_FAILED: ${error.message}`);
  }
}

async function markRetryableLookupFailure(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  lookup: Extract<TossLookupResult, { kind: "retryable_error" }>,
  checkedAt: string,
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: "none",
    error_code: lookup.status
      ? `TOSS_LOOKUP_${lookup.status}`
      : "TOSS_LOOKUP_RETRYABLE",
    error_message: lookup.message,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: "retryable_error",
        checked_at: checkedAt,
        order_id: attempt.order_id,
        status_code: lookup.status ?? null,
        response: lookup.payload ?? null,
      },
    }),
  });
}

async function markSameOrderRetry(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  params: {
    message: string;
    payload: unknown;
    checkedAt: string;
  },
) {
  await updateAttempt(admin, attempt.id, {
    status: "initiated",
    activation_status: "not_started",
    recovery_status: "none",
    charge_dispatched_at: null,
    error_code: ORDER_NOT_FOUND_RETRY_CODE,
    error_message: params.message,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: "retry_same_order",
        checked_at: params.checkedAt,
        order_id: attempt.order_id,
        provider_posts: 0,
        response: params.payload,
      },
    }),
  });
}

async function markBlockedLookupResult(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  params: {
    code: string;
    message: string;
    payload: unknown;
    checkedAt: string;
  },
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: "pending",
    error_code: params.code,
    error_message: params.message,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: "blocked",
        checked_at: params.checkedAt,
        order_id: attempt.order_id,
        reason: params.code,
        response: params.payload,
      },
    }),
  });
}

async function recoverActivation(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  checkedAt: string,
) {
  const { data: recoveryResult, error: recoveryError } = await admin.rpc(
    "recover_payment_attempt_activation",
    { p_attempt_id: attempt.id },
  );

  if (recoveryError) {
    await updateAttempt(admin, attempt.id, {
      status: "activation_failed",
      activation_status: "failed",
      recovery_status: "pending",
      error_code: recoveryError.code || "RECOVERY_RPC_FAILED",
      error_message: recoveryError.message,
      provider_response: sanitizeProviderPayload({
        reconciliation: {
          status: "recovery_failed",
          checked_at: checkedAt,
          order_id: attempt.order_id,
        },
      }),
    });
    return {
      paymentAttemptId: attempt.id,
      orderId: attempt.order_id,
      ok: false,
      action: attempt.reconciliation_action,
      recoveredPayment: true,
      retryable: true,
      error: recoveryError.message,
    };
  }

  return {
    paymentAttemptId: attempt.id,
    orderId: attempt.order_id,
    ok: true,
    action: attempt.reconciliation_action,
    paymentKey: attempt.payment_key,
    recovery: recoveryResult,
  };
}

async function storeDonePaymentBeforeRecovery(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  payment: Record<string, unknown>,
  paymentKey: string,
  checkedAt: string,
) {
  await updateAttempt(admin, attempt.id, {
    status: "activation_pending",
    activation_status: "pending",
    recovery_status: "none",
    payment_key: paymentKey,
    error_code: null,
    error_message: null,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: "payment_found",
        checked_at: checkedAt,
        order_id: attempt.order_id,
      },
      payment,
    }),
  });
}

export async function processReconciliationAttempt(
  admin: AdminClientLike,
  attempt: ReconciliationAttempt,
  options: ProcessOptions,
): Promise<Record<string, unknown>> {
  const checkedAt = (options.now ?? (() => new Date()))().toISOString();
  const fetchImpl = options.fetchImpl ?? fetch;

  try {
    if (attempt.reconciliation_action === "recovery_only") {
      if (!attempt.payment_key) {
        throw new Error("RECOVERY_PAYMENT_KEY_REQUIRED");
      }
      return await recoverActivation(admin, attempt, checkedAt);
    }

    if (attempt.reconciliation_action !== "lookup_required") {
      throw new Error(
        `UNKNOWN_RECONCILIATION_ACTION:${attempt.reconciliation_action}`,
      );
    }

    const lookup = await lookupTossPaymentByOrderId(
      attempt.order_id,
      options.tossSecret,
      fetchImpl,
    );

    if (lookup.kind === "retryable_error") {
      await markRetryableLookupFailure(admin, attempt, lookup, checkedAt);
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        providerPosts: 0,
        retryable: true,
        error: lookup.message,
      };
    }

    const settlement = classifyOrderLookup(lookup, {
      orderId: attempt.order_id,
      amountKrw: Number(attempt.amount_krw),
    });
    const recorded = isRecordedPayment({
      orderId: attempt.order_id,
      status: attempt.status,
      paymentKey: attempt.payment_key,
    });
    if (recorded && settlement.kind === "paid" &&
      settlement.paymentKey === attempt.payment_key) {
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: true,
        action: attempt.reconciliation_action,
        alreadyRecorded: true,
        providerPosts: 0,
        paymentKey: attempt.payment_key,
      };
    }
    if (recorded) {
      await markBlockedLookupResult(admin, attempt, {
        code: "TOSS_RECORDED_PAYMENT_CONFLICT",
        message: "Recorded payment was not replaced by a later lookup",
        payload: lookup.kind === "found" ? lookup.payment : lookup.payload,
        checkedAt,
      });
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        providerPosts: 0,
        retryable: false,
        error: "Recorded payment was not replaced",
      };
    }

    if (settlement.kind === "retry_same_order") {
      await markSameOrderRetry(admin, attempt, {
        message: settlement.message,
        payload: settlement.payload,
        checkedAt,
      });
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        providerPosts: 0,
        retryable: true,
        sameOrderRetry: true,
        error: settlement.message,
      };
    }

    if (settlement.kind !== "paid") {
      await markBlockedLookupResult(admin, attempt, {
        code: settlement.code,
        message: settlement.message,
        payload: settlement.payload,
        checkedAt,
      });
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        providerPosts: 0,
        retryable: false,
        error: settlement.kind === "needs_review"
          ? settlement.message.split("; ")
          : settlement.message,
      };
    }

    await storeDonePaymentBeforeRecovery(
      admin,
      attempt,
      settlement.payload,
      settlement.paymentKey,
      checkedAt,
    );

    return await recoverActivation(
      admin,
      {
        ...attempt,
        status: "activation_pending",
        activation_status: "pending",
        recovery_status: "none",
        payment_key: settlement.paymentKey,
      },
      checkedAt,
    );
  } catch (error) {
    const message = errorMessage(error);
    try {
      await updateAttempt(admin, attempt.id, {
        recovery_status: "none",
        error_code: "RECONCILIATION_UNEXPECTED_ERROR",
        error_message: message,
        provider_response: sanitizeProviderPayload({
          reconciliation: {
            status: "unexpected_error",
            checked_at: checkedAt,
            order_id: attempt.order_id,
            error: message,
          },
        }),
      });
    } catch (updateError) {
      console.error("RECONCILIATION_ERROR_UPDATE_FAILED", {
        paymentAttemptId: attempt.id,
        error: errorMessage(updateError),
      });
    }
    return {
      paymentAttemptId: attempt.id,
      orderId: attempt.order_id,
      ok: false,
      action: attempt.reconciliation_action,
      retryable: true,
      error: message,
    };
  }
}
