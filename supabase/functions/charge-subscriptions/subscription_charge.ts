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
  const billingKey = String(claim.billing_key_ref || "");
  const customerKey = String(claim.customer_key || "");
  const orderId = String(claim.order_id || "");
  const paymentAttemptId = String(claim.payment_attempt_id || "");
  const amountKrw = Number(claim.amount_krw || 10000);
  let chargeSucceeded = false;

  try {
    if (!paymentAttemptId || !billingKey || !customerKey || !orderId) {
      throw new Error("Missing billing key");
    }

    if (!ownerId) throw new Error("Gym owner not found");

    const chargeOutcome = await chargeTossBilling({
      billingKey,
      authorization: tossAuthHeader(options.tossSecret),
      body: {
        customerKey,
        amount: amountKrw,
        orderId,
        orderName: "re;member Pro 월간 자동결제",
      },
      fetchImpl: options.fetchImpl,
    });

    if (chargeOutcome.kind === "uncertain") {
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
      });
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
      });
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

    await admin.from("checkout_sessions").insert({
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
      raw: { mode: "auto_renew", ...charged },
    });

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
