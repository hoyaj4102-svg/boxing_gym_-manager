import { sanitizeProviderPayload } from "../_shared/sanitize_provider_payload.ts";
import { chargeTossBilling } from "../_shared/toss_charge_outcome.ts";

export type ClaimedSubscriptionCharge = {
  payment_attempt_id: string;
  gym_id: string;
  user_id: string | null;
  order_id: string;
  customer_key: string;
  billing_key_ref: string;
  target_period_start: string;
  target_period_end: string;
  amount_krw: number;
};

export type AdminClientLike = {
  from(table: string): {
    update(values: Record<string, unknown>): {
      eq(
        column: string,
        value: string,
      ): Promise<{ error: null | { message: string; code?: string } }>;
    };
    insert(
      values: Record<string, unknown>,
    ): Promise<{ error: null | { message: string; code?: string } }>;
  };
  rpc(
    name: string,
    args: Record<string, unknown>,
  ): Promise<
    { data: unknown; error: null | { message: string; code?: string } }
  >;
};

type ProcessOptions = {
  tossSecret: string;
  fetchImpl?: typeof fetch;
  now?: () => Date;
  dryRun?: boolean;
};

class NonTerminalChargeError extends Error {
  code: string;
  chargeResult: string;
  persistAttempt: boolean;

  constructor(
    code: string,
    message: string,
    chargeResult = "internal_error",
    persistAttempt = true,
  ) {
    super(message);
    this.name = "NonTerminalChargeError";
    this.code = code;
    this.chargeResult = chargeResult;
    this.persistAttempt = persistAttempt;
  }
}

function tossAuthHeader(secret: string) {
  if (!secret) {
    throw new NonTerminalChargeError(
      "AUTO_RENEW_TOSS_SECRET_MISSING",
      "TOSS_SECRET_KEY is missing",
    );
  }
  return `Basic ${btoa(`${secret}:`)}`;
}

export async function resolveBillingCredential(
  admin: AdminClientLike,
  claim: ClaimedSubscriptionCharge,
): Promise<string> {
  const gymId = String(claim.gym_id || "");
  if (!gymId) {
    throw new NonTerminalChargeError(
      "BILLING_CREDENTIAL_UNAVAILABLE",
      "Billing credential store is unavailable",
      "credential_unavailable",
      false,
    );
  }

  const { data, error } = await admin.rpc("read_gym_billing_credential", {
    p_gym_id: gymId,
  });
  if (error) {
    throw new NonTerminalChargeError(
      "BILLING_CREDENTIAL_UNAVAILABLE",
      "Billing credential store is unavailable",
      "credential_unavailable",
      false,
    );
  }
  if (typeof data === "string" && data.trim()) {
    return data.trim();
  }
  return String(claim.billing_key_ref || "");
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

async function updatePaymentAttempt(
  admin: AdminClientLike,
  attemptId: string | null,
  values: Record<string, unknown>,
  options: { throwOnError?: boolean } = {},
) {
  if (!attemptId) {
    if (options.throwOnError) {
      throw new Error("PAYMENT_ATTEMPT_ID_REQUIRED");
    }
    return;
  }
  const { error } = await admin
    .from("payment_attempts")
    .update(values)
    .eq("id", attemptId);
  if (error) {
    console.error("PAYMENT_ATTEMPT_UPDATE_FAILED", {
      attemptId,
      error: error.message,
    });
    if (options.throwOnError) {
      throw new Error(`PAYMENT_ATTEMPT_UPDATE_FAILED: ${error.message}`);
    }
  }
}

async function markGymPastDue(
  admin: AdminClientLike,
  gymId: string,
  checkedAt: string,
) {
  await admin
    .from("gyms")
    .update({
      auto_renew: false,
      subscription_status: "past_due",
      updated_at: checkedAt,
    })
    .eq("id", gymId);
}

async function activatePaymentAttempt(
  admin: AdminClientLike,
  attemptId: string,
) {
  const { data, error } = await admin.rpc("activate_payment_attempt", {
    p_attempt_id: attemptId,
  });

  if (error) return error;

  const result = data && typeof data === "object"
    ? data as Record<string, unknown>
    : {};
  if (result.ok === false) {
    return new Error(
      String(result.error_message || result.error_code || "Activation failed"),
    );
  }

  return null;
}

export async function processClaimedSubscriptionCharge(
  admin: AdminClientLike,
  claim: ClaimedSubscriptionCharge,
  options: ProcessOptions,
): Promise<Record<string, unknown>> {
  const checkedAt = (options.now ?? (() => new Date()))().toISOString();
  const gymId = String(claim.gym_id || "");
  const ownerId = claim.user_id ? String(claim.user_id) : "";
  const customerKey = String(claim.customer_key || "");
  const orderId = String(claim.order_id || "");
  const paymentAttemptId = String(claim.payment_attempt_id || "");
  const amountKrw = Number(claim.amount_krw || 10000);
  let billingKey = "";
  let chargeSucceeded = false;

  if (options.dryRun) {
    return {
      gymId,
      ok: true,
      dryRun: true,
      orderId,
      paymentAttemptId,
      chargeResult: "not_sent",
      providerCalls: 0,
    };
  }

  try {
    billingKey = await resolveBillingCredential(admin, claim);
    if (!paymentAttemptId || !billingKey || !customerKey || !orderId) {
      throw new NonTerminalChargeError(
        "AUTO_RENEW_CLAIM_INVALID",
        "Missing billing key",
      );
    }

    if (!ownerId) {
      throw new NonTerminalChargeError(
        "AUTO_RENEW_OWNER_NOT_FOUND",
        "Gym owner not found",
      );
    }

    const authorization = tossAuthHeader(options.tossSecret);
    const dispatch = await admin.rpc("claim_subscription_charge_dispatch", {
      p_attempt_id: paymentAttemptId,
    });
    if (dispatch.error || dispatch.data !== true) {
      throw new NonTerminalChargeError(
        dispatch.error
          ? "CHARGE_DISPATCH_UNAVAILABLE"
          : "CHARGE_ALREADY_DISPATCHED",
        dispatch.error
          ? "Charge dispatch is unavailable"
          : "Charge was already dispatched",
        dispatch.error ? "dispatch_unavailable" : "already_dispatched",
        false,
      );
    }

    const chargeOutcome = await chargeTossBilling({
      billingKey,
      authorization,
      body: {
        customerKey,
        amount: amountKrw,
        orderId,
        orderName: "re;member Pro 월간 자동결제",
      },
      fetchImpl: options.fetchImpl,
    });

    if (chargeOutcome.kind === "uncertain") {
      try {
        await updatePaymentAttempt(admin, paymentAttemptId, {
          status: "charge_failed",
          activation_status: "not_started",
          recovery_status: "pending",
          error_code: chargeOutcome.code,
          error_message: chargeOutcome.message,
          provider_response: sanitizeProviderPayload({
            mode: "auto_renew_charge_uncertain",
            charge: chargeOutcome.payload,
          }),
        }, { throwOnError: true });
      } catch (error) {
        throw new NonTerminalChargeError(
          "AUTO_RENEW_UNCERTAIN_STATE_UPDATE_FAILED",
          errorMessage(error),
          "uncertain_persist_failed",
          false,
        );
      }
      return {
        gymId,
        ok: false,
        orderId,
        paymentAttemptId,
        retryable: true,
        chargeResult: "uncertain",
        error: chargeOutcome.message,
      };
    }

    if (chargeOutcome.kind === "rejected") {
      try {
        await updatePaymentAttempt(admin, paymentAttemptId, {
          status: "charge_failed",
          activation_status: "not_started",
          recovery_status: "none",
          error_code: chargeOutcome.code,
          error_message: chargeOutcome.message,
          provider_response: sanitizeProviderPayload({
            mode: "auto_renew_charge_rejected",
            charge: chargeOutcome.payload,
          }),
        }, { throwOnError: true });
      } catch (error) {
        throw new NonTerminalChargeError(
          "AUTO_RENEW_REJECTED_STATE_UPDATE_FAILED",
          errorMessage(error),
          "rejected_persist_failed",
          false,
        );
      }
      await markGymPastDue(admin, gymId, checkedAt);
      return {
        gymId,
        ok: false,
        orderId,
        paymentAttemptId,
        chargeResult: "rejected",
        error: chargeOutcome.message,
      };
    }

    const charged = chargeOutcome.payload;
    const paymentKey = chargeOutcome.paymentKey;
    chargeSucceeded = true;

    await updatePaymentAttempt(admin, paymentAttemptId, {
      status: "activation_pending",
      activation_status: "pending",
      recovery_status: "none",
      payment_key: paymentKey,
      provider_response: sanitizeProviderPayload(charged),
    }, { throwOnError: true });

    const { error: checkoutSessionError } = await admin.from(
      "checkout_sessions",
    ).insert({
      gym_id: gymId,
      user_id: ownerId,
      provider: "toss",
      interval: "monthly",
      amount_krw: amountKrw,
      amount_usd_cents: 0,
      currency: "KRW",
      status: "completed",
      order_id: orderId,
      provider_session_id: paymentKey,
      completed_at: checkedAt,
      raw: sanitizeProviderPayload({ mode: "auto_renew", ...charged }),
    });
    if (checkoutSessionError) {
      throw new Error(
        `CHECKOUT_SESSION_INSERT_FAILED: ${checkoutSessionError.message}`,
      );
    }

    const activateError = await activatePaymentAttempt(
      admin,
      paymentAttemptId,
    );

    if (activateError) {
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: "activation_failed",
        activation_status: "failed",
        recovery_status: "pending",
        error_message: activateError.message,
      });
      throw activateError;
    }

    await updatePaymentAttempt(admin, paymentAttemptId, {
      status: "completed",
      activation_status: "succeeded",
      recovery_status: "none",
      activated_at: checkedAt,
      error_code: null,
      error_message: null,
    });

    return { gymId, ok: true, orderId, paymentAttemptId };
  } catch (chargeError) {
    const message = errorMessage(chargeError);
    if (chargeError instanceof NonTerminalChargeError) {
      if (chargeError.persistAttempt) {
        await updatePaymentAttempt(admin, paymentAttemptId, {
          status: "charge_failed",
          activation_status: "not_started",
          recovery_status: "none",
          error_code: chargeError.code,
          error_message: message,
        });
      }
      return {
        gymId,
        ok: false,
        orderId,
        paymentAttemptId,
        retryable: true,
        chargeResult: chargeError.chargeResult,
        error: message,
      };
    }

    if (!chargeSucceeded) {
      await updatePaymentAttempt(admin, paymentAttemptId, {
        status: "charge_failed",
        activation_status: "not_started",
        recovery_status: "none",
        error_message: message,
      });
      await markGymPastDue(admin, gymId, checkedAt);
    }
    return { gymId, ok: false, orderId, paymentAttemptId, error: message };
  }
}
