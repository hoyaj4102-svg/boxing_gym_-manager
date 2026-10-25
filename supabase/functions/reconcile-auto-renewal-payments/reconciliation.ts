const TOSS_LOOKUP_TIMEOUT_MS = 10000;

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

type TossLookupResult =
  | { kind: "found"; payment: Record<string, unknown> }
  | { kind: "not_found"; status: number; payload: unknown }
  | {
    kind: "retryable_error";
    status?: number;
    message: string;
    payload?: unknown;
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

const SENSITIVE_KEYS = new Set([
  "authorization",
  "billingkey",
  "card",
  "cardnumber",
  "customerkey",
  "secret",
  "secretkey",
]);

function tossAuthHeader(secret: string) {
  if (!secret) throw new Error("TOSS_SECRET_KEY is missing");
  return `Basic ${btoa(`${secret}:`)}`;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function sanitizeProviderPayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeProviderPayload);
  }

  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const normalizedKey = key.replace(/[_\-\s]/g, "").toLowerCase();
        if (SENSITIVE_KEYS.has(normalizedKey)) {
          return [key, "[REDACTED]"];
        }
        return [key, sanitizeProviderPayload(entry)];
      }),
    );
  }

  return value;
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

export function validateDonePayment(
  attempt: ReconciliationAttempt,
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
  if (orderId !== attempt.order_id) failures.push("orderId mismatch");
  if (
    !Number.isFinite(totalAmount) || totalAmount !== Number(attempt.amount_krw)
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
        retryable: true,
        error: lookup.message,
      };
    }

    if (lookup.kind === "not_found") {
      await markBlockedLookupResult(admin, attempt, {
        code: "TOSS_PAYMENT_NOT_FOUND_UNCONFIRMED",
        message:
          "Toss payment was not found for orderId; keeping attempt blocked for retry/manual review",
        payload: lookup.payload,
        checkedAt,
      });
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        retryable: true,
        error: "Toss payment not found; not confirmed safe for a new charge",
      };
    }

    const validation = validateDonePayment(attempt, lookup.payment);
    if (!validation.ok) {
      await markBlockedLookupResult(admin, attempt, {
        code: "TOSS_PAYMENT_VALIDATION_FAILED",
        message: validation.failures.join("; "),
        payload: lookup.payment,
        checkedAt,
      });
      return {
        paymentAttemptId: attempt.id,
        orderId: attempt.order_id,
        ok: false,
        action: attempt.reconciliation_action,
        retryable: false,
        error: validation.failures,
      };
    }

    await storeDonePaymentBeforeRecovery(
      admin,
      attempt,
      lookup.payment,
      validation.paymentKey,
      checkedAt,
    );

    return await recoverActivation(
      admin,
      {
        ...attempt,
        status: "activation_pending",
        activation_status: "pending",
        recovery_status: "none",
        payment_key: validation.paymentKey,
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
