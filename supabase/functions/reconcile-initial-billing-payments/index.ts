import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

const DEFAULT_STALE_MINUTES = 10;
const MAX_BATCH_SIZE = 50;
const TOSS_LOOKUP_TIMEOUT_MS = 10000;

type InitialReconciliationAttempt = {
  id: string;
  gym_id: string;
  user_id: string | null;
  order_id: string;
  amount_krw: number;
  customer_key: string | null;
  billing_key_ref: string | null;
  status: string;
  activation_status: string;
  recovery_status: string;
  target_period_start: string | null;
  target_period_end: string | null;
  provider_response: unknown;
  created_at: string;
  updated_at: string;
};

type TossLookupResult =
  | { kind: 'found'; payment: Record<string, unknown> }
  | { kind: 'not_found'; status: number; payload: unknown }
  | { kind: 'retryable_error'; status?: number; message: string; payload?: unknown };

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  return `Basic ${btoa(`${secret}:`)}`;
}

function isAuthorizedCron(req: Request, cronSecret: string) {
  if (!cronSecret) return false;
  const auth = req.headers.get('Authorization') || '';
  const headerSecret = req.headers.get('x-cron-secret') || '';
  return auth === `Bearer ${cronSecret}` || headerSecret === cronSecret;
}

const SENSITIVE_KEYS = new Set([
  'authorization',
  'billingkey',
  'card',
  'cardnumber',
  'customerkey',
  'secret',
  'secretkey'
]);

function sanitizeProviderPayload(value: unknown): unknown {
  if (Array.isArray(value)) {
    return value.map(sanitizeProviderPayload);
  }

  if (value && typeof value === 'object') {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>).map(([key, entry]) => {
        const normalizedKey = key.replace(/[_\-\s]/g, '').toLowerCase();
        if (SENSITIVE_KEYS.has(normalizedKey)) {
          return [key, '[REDACTED]'];
        }
        return [key, sanitizeProviderPayload(entry)];
      })
    );
  }

  return value;
}

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
}

function asRecord(value: unknown): Record<string, unknown> {
  return value && typeof value === 'object' && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function mergeProviderResponse(
  attempt: InitialReconciliationAttempt,
  values: Record<string, unknown>
) {
  return {
    ...asRecord(attempt.provider_response),
    ...values
  };
}

async function readJsonResponse(response: Response) {
  const text = await response.text();
  if (!text) return { payload: null, malformed: false };
  try {
    return { payload: JSON.parse(text), malformed: false };
  } catch {
    return { payload: { raw: text }, malformed: true };
  }
}

async function lookupTossPaymentByOrderId(orderId: string): Promise<TossLookupResult> {
  const controller = new AbortController();
  const timeoutId = setTimeout(() => controller.abort(), TOSS_LOOKUP_TIMEOUT_MS);

  try {
    const response = await fetch(
      `https://api.tosspayments.com/v1/payments/orders/${encodeURIComponent(orderId)}`,
      {
        method: 'GET',
        headers: {
          Authorization: tossAuthHeader()
        },
        signal: controller.signal
      }
    );
    const { payload, malformed } = await readJsonResponse(response);

    if (response.status === 404) {
      return { kind: 'not_found', status: response.status, payload };
    }

    if (malformed) {
      return {
        kind: 'retryable_error',
        status: response.status,
        message: 'Malformed Toss lookup JSON',
        payload
      };
    }

    if (response.ok && payload && typeof payload === 'object' && !Array.isArray(payload)) {
      return { kind: 'found', payment: payload as Record<string, unknown> };
    }

    return {
      kind: 'retryable_error',
      status: response.status,
      message: `Unexpected Toss lookup response: ${response.status}`,
      payload
    };
  } catch (error) {
    return {
      kind: 'retryable_error',
      message: errorMessage(error)
    };
  } finally {
    clearTimeout(timeoutId);
  }
}

function validateDonePayment(
  attempt: InitialReconciliationAttempt,
  payment: Record<string, unknown>
) {
  const paymentKey = typeof payment.paymentKey === 'string' ? payment.paymentKey : '';
  const orderId = typeof payment.orderId === 'string' ? payment.orderId : '';
  const status = typeof payment.status === 'string' ? payment.status : '';
  const totalAmount = Number(payment.totalAmount);

  const failures: string[] = [];
  if (status !== 'DONE') failures.push(`status is ${status || 'missing'}`);
  if (orderId !== attempt.order_id) failures.push('orderId mismatch');
  if (!Number.isFinite(totalAmount) || totalAmount !== Number(attempt.amount_krw)) {
    failures.push('totalAmount mismatch');
  }
  if (!paymentKey) failures.push('paymentKey missing');

  return {
    ok: failures.length === 0,
    paymentKey,
    status,
    failures
  };
}

async function updateAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string,
  values: Record<string, unknown>
) {
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);

  if (error) {
    throw new Error(`PAYMENT_ATTEMPT_UPDATE_FAILED: ${error.message}`);
  }
}

async function markConfirmedNoPayment(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  payload: unknown
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'completed',
    error_code: 'TOSS_PAYMENT_NOT_FOUND',
    error_message: 'Toss payment was not found for stable initial billing orderId',
    provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
      initial_reconciliation: {
        result: 'confirmed_no_payment',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        response: payload
      }
    }))
  });
}

async function markRetryableLookupFailure(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  lookup: Extract<TossLookupResult, { kind: 'retryable_error' }>
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'none',
    error_code: lookup.status ? `TOSS_LOOKUP_${lookup.status}` : 'TOSS_LOOKUP_RETRYABLE',
    error_message: lookup.message,
    provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
      initial_reconciliation: {
        result: 'retryable_error',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        status_code: lookup.status ?? null,
        response: lookup.payload ?? null
      }
    }))
  });
}

async function markNonDonePayment(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  payment: Record<string, unknown>,
  status: string
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'none',
    error_code: `TOSS_PAYMENT_${status || 'STATUS_MISSING'}`,
    error_message: 'Toss payment exists but is not DONE; no new charge will be attempted',
    provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
      initial_reconciliation: {
        result: 'payment_not_done',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        status: status || null
      },
      payment
    }))
  });
}

async function markValidationFailure(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  payment: Record<string, unknown>,
  failures: string[]
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'failed',
    error_code: 'TOSS_PAYMENT_VALIDATION_FAILED',
    error_message: failures.join('; '),
    provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
      initial_reconciliation: {
        result: 'validation_failed',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        failures
      },
      payment
    }))
  });
}

async function storeDonePaymentBeforeRecovery(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  payment: Record<string, unknown>,
  paymentKey: string
) {
  await updateAttempt(admin, attempt.id, {
    status: 'activation_pending',
    activation_status: 'pending',
    recovery_status: 'none',
    payment_key: paymentKey,
    error_code: null,
    error_message: null,
    provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
      initial_reconciliation: {
        result: 'payment_found',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id
      },
      payment
    }))
  });
}

async function markRecoveryFailure(
  admin: ReturnType<typeof getAdminClient>,
  attempt: InitialReconciliationAttempt,
  message: string,
  code: string
) {
  await updateAttempt(admin, attempt.id, {
    status: 'activation_failed',
    activation_status: 'failed',
    recovery_status: 'pending',
    error_code: code,
    error_message: message
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return textResponse('Method not allowed', 405);
  }

  try {
    const cronSecret = Deno.env.get('CRON_SECRET') || '';
    if (!isAuthorizedCron(req, cronSecret)) {
      return textResponse('Unauthorized', 401);
    }

    const admin = getAdminClient();
    const staleBefore = new Date(Date.now() - DEFAULT_STALE_MINUTES * 60 * 1000).toISOString();

    const { data: claimedAttempts, error: claimError } = await admin.rpc(
      'claim_stale_initial_billing_reconciliation_attempts',
      {
        p_stale_before: staleBefore,
        p_limit: MAX_BATCH_SIZE
      }
    );

    if (claimError) {
      return jsonResponse({ ok: false, error: claimError.message }, 400);
    }

    const results: Array<Record<string, unknown>> = [];

    for (const attempt of (claimedAttempts || []) as InitialReconciliationAttempt[]) {
      try {
        const lookup = await lookupTossPaymentByOrderId(attempt.order_id);

        if (lookup.kind === 'retryable_error') {
          await markRetryableLookupFailure(admin, attempt, lookup);
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            retryable: true,
            error: lookup.message
          });
          continue;
        }

        if (lookup.kind === 'not_found') {
          await markConfirmedNoPayment(admin, attempt, lookup.payload);
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: true,
            confirmedNoPayment: true
          });
          continue;
        }

        const validation = validateDonePayment(attempt, lookup.payment);

        if (validation.status !== 'DONE') {
          await markNonDonePayment(admin, attempt, lookup.payment, validation.status);
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            retryable: true,
            error: `Payment status is ${validation.status || 'missing'}`
          });
          continue;
        }

        if (!validation.ok) {
          await markValidationFailure(admin, attempt, lookup.payment, validation.failures);
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            retryable: false,
            error: validation.failures
          });
          continue;
        }

        await storeDonePaymentBeforeRecovery(
          admin,
          attempt,
          lookup.payment,
          validation.paymentKey
        );

        const { data: recoveryResult, error: recoveryError } = await admin.rpc(
          'recover_payment_attempt_activation',
          { p_attempt_id: attempt.id }
        );

        const recovery = recoveryResult && typeof recoveryResult === 'object'
          ? recoveryResult as Record<string, unknown>
          : {};
        if (recoveryError || recovery.ok === false) {
          const message = recoveryError?.message
            || String(recovery.error_message || recovery.error_code || 'Recovery failed');
          await markRecoveryFailure(
            admin,
            attempt,
            message,
            recoveryError?.code || String(recovery.error_code || 'INITIAL_RECOVERY_FAILED')
          );
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            recoveredPayment: true,
            error: message
          });
          continue;
        }

        results.push({
          paymentAttemptId: attempt.id,
          orderId: attempt.order_id,
          ok: true,
          paymentKey: validation.paymentKey,
          recovery
        });
      } catch (error) {
        const message = errorMessage(error);
        try {
          await updateAttempt(admin, attempt.id, {
            recovery_status: 'none',
            error_code: 'INITIAL_RECONCILIATION_UNEXPECTED_ERROR',
            error_message: message,
            provider_response: sanitizeProviderPayload(mergeProviderResponse(attempt, {
              initial_reconciliation: {
                result: 'unexpected_error',
                checked_at: new Date().toISOString(),
                order_id: attempt.order_id,
                error: message
              }
            }))
          });
        } catch (updateError) {
          console.error('INITIAL_RECONCILIATION_ERROR_UPDATE_FAILED', {
            paymentAttemptId: attempt.id,
            error: errorMessage(updateError)
          });
        }
        results.push({
          paymentAttemptId: attempt.id,
          orderId: attempt.order_id,
          ok: false,
          retryable: true,
          error: message
        });
      }
    }

    return jsonResponse({
      ok: true,
      checkedAt: new Date().toISOString(),
      staleBefore,
      count: results.length,
      results
    });
  } catch (error) {
    const message = errorMessage(error);
    return jsonResponse({ ok: false, error: message || 'Unknown error' }, 400);
  }
});
