import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

const DEFAULT_STALE_MINUTES = 10;
const MAX_BATCH_SIZE = 50;
const TOSS_LOOKUP_TIMEOUT_MS = 10000;

type ReconciliationAttempt = {
  id: string;
  gym_id: string;
  order_id: string;
  amount_krw: number;
  customer_key: string | null;
  billing_key_ref: string | null;
  target_period_start: string | null;
  target_period_end: string | null;
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

async function readJsonResponse(response: Response) {
  const text = await response.text();
  if (!text) return null;
  try {
    return JSON.parse(text);
  } catch {
    return { raw: text };
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
    const payload = await readJsonResponse(response);

    if (response.ok && payload && typeof payload === 'object' && !Array.isArray(payload)) {
      return { kind: 'found', payment: payload as Record<string, unknown> };
    }

    if (response.status === 404) {
      return { kind: 'not_found', status: response.status, payload };
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
  attempt: ReconciliationAttempt,
  payment: Record<string, unknown>
) {
  const paymentKey = typeof payment.paymentKey === 'string' ? payment.paymentKey : '';
  const orderId = typeof payment.orderId === 'string' ? payment.orderId : '';
  const status = typeof payment.status === 'string' ? payment.status : '';
  const totalAmount = Number(payment.totalAmount);

  const failures: string[] = [];
  if (!paymentKey) failures.push('paymentKey missing');
  if (orderId !== attempt.order_id) failures.push('orderId mismatch');
  if (!Number.isFinite(totalAmount) || totalAmount !== Number(attempt.amount_krw)) {
    failures.push('totalAmount mismatch');
  }
  if (status !== 'DONE') failures.push(`status is ${status || 'missing'}`);

  return {
    ok: failures.length === 0,
    paymentKey,
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

async function markRetryableLookupFailure(
  admin: ReturnType<typeof getAdminClient>,
  attempt: ReconciliationAttempt,
  lookup: Extract<TossLookupResult, { kind: 'retryable_error' }>
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'none',
    error_code: lookup.status ? `TOSS_LOOKUP_${lookup.status}` : 'TOSS_LOOKUP_RETRYABLE',
    error_message: lookup.message,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: 'retryable_error',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        status_code: lookup.status ?? null,
        response: lookup.payload ?? null
      }
    })
  });
}

async function markNonSuccessfulLookup(
  admin: ReturnType<typeof getAdminClient>,
  attempt: ReconciliationAttempt,
  params: {
    code: string;
    message: string;
    payload: unknown;
  }
) {
  await updateAttempt(admin, attempt.id, {
    recovery_status: 'failed',
    error_code: params.code,
    error_message: params.message,
    provider_response: sanitizeProviderPayload({
      reconciliation: {
        status: 'not_recovered',
        checked_at: new Date().toISOString(),
        order_id: attempt.order_id,
        reason: params.code,
        response: params.payload
      }
    })
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
      'claim_stale_auto_renewal_reconciliation_attempts',
      {
        p_stale_before: staleBefore,
        p_limit: MAX_BATCH_SIZE
      }
    );

    if (claimError) {
      return jsonResponse({ ok: false, error: claimError.message }, 400);
    }

    const results: Array<Record<string, unknown>> = [];

    for (const attempt of (claimedAttempts || []) as ReconciliationAttempt[]) {
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
          await markNonSuccessfulLookup(admin, attempt, {
            code: 'TOSS_PAYMENT_NOT_FOUND',
            message: 'Toss payment was not found for orderId',
            payload: lookup.payload
          });
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            retryable: false,
            error: 'Toss payment not found'
          });
          continue;
        }

        const validation = validateDonePayment(attempt, lookup.payment);
        if (!validation.ok) {
          await markNonSuccessfulLookup(admin, attempt, {
            code: 'TOSS_PAYMENT_VALIDATION_FAILED',
            message: validation.failures.join('; '),
            payload: lookup.payment
          });
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            retryable: false,
            error: validation.failures
          });
          continue;
        }

        await updateAttempt(admin, attempt.id, {
          status: 'activation_pending',
          activation_status: 'pending',
          recovery_status: 'none',
          payment_key: validation.paymentKey,
          error_code: null,
          error_message: null,
          provider_response: sanitizeProviderPayload({
            reconciliation: {
              status: 'payment_found',
              checked_at: new Date().toISOString(),
              order_id: attempt.order_id
            },
            payment: lookup.payment
          })
        });

        const { data: recoveryResult, error: recoveryError } = await admin.rpc(
          'recover_payment_attempt_activation',
          { p_attempt_id: attempt.id }
        );

        if (recoveryError) {
          await updateAttempt(admin, attempt.id, {
            status: 'activation_failed',
            activation_status: 'failed',
            recovery_status: 'pending',
            error_code: recoveryError.code || 'RECOVERY_RPC_FAILED',
            error_message: recoveryError.message
          });
          results.push({
            paymentAttemptId: attempt.id,
            orderId: attempt.order_id,
            ok: false,
            recoveredPayment: true,
            error: recoveryError.message
          });
          continue;
        }

        results.push({
          paymentAttemptId: attempt.id,
          orderId: attempt.order_id,
          ok: true,
          paymentKey: validation.paymentKey,
          recovery: recoveryResult
        });
      } catch (error) {
        const message = errorMessage(error);
        try {
          await updateAttempt(admin, attempt.id, {
            recovery_status: 'none',
            error_code: 'RECONCILIATION_UNEXPECTED_ERROR',
            error_message: message,
            provider_response: sanitizeProviderPayload({
              reconciliation: {
                status: 'unexpected_error',
                checked_at: new Date().toISOString(),
                order_id: attempt.order_id,
                error: message
              }
            })
          });
        } catch (updateError) {
          console.error('RECONCILIATION_ERROR_UPDATE_FAILED', {
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
