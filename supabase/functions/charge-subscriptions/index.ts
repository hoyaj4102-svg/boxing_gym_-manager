import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

const AMOUNT_KRW = 10000;
const CLAIM_LIMIT = 50;

type ClaimedSubscriptionCharge = {
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

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  return `Basic ${btoa(`${secret}:`)}`;
}

/**
 * Monthly auto-charge for Toss billing keys.
 * Protect with either:
 *   Authorization: Bearer <CRON_SECRET>
 *   or header x-cron-secret: <CRON_SECRET>
 * JWT verification is disabled for this function (see config.toml).
 */
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

async function updatePaymentAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null,
  values: Record<string, unknown>,
  options: { throwOnError?: boolean } = {}
) {
  if (!attemptId) {
    if (options.throwOnError) {
      throw new Error('PAYMENT_ATTEMPT_ID_REQUIRED');
    }
    return;
  }
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);
  if (error) {
    console.error('PAYMENT_ATTEMPT_UPDATE_FAILED', {
      attemptId,
      error: error.message
    });
    if (options.throwOnError) {
      throw new Error(`PAYMENT_ATTEMPT_UPDATE_FAILED: ${error.message}`);
    }
  }
}

async function activateGymProWithFallback(
  admin: ReturnType<typeof getAdminClient>,
  params: {
    gymId: string;
    customerKey: string;
    billingKey: string;
    paymentKey: string;
    charged: Record<string, unknown>;
  }
) {
  const rpcPayload = {
    p_gym_id: params.gymId,
    p_provider: 'toss',
    p_interval: 'monthly',
    p_amount_krw: AMOUNT_KRW,
    p_customer_id: params.customerKey,
    p_subscription_id: params.billingKey,
    p_provider_ref: params.paymentKey,
    p_raw: params.charged
  };

  const { error: activateError } = await admin.rpc('activate_gym_pro', {
    ...rpcPayload,
    p_auto_renew: true
  });

  if (!activateError) return null;

  const message = String(activateError.message || '');
  if (message.includes('p_auto_renew') || message.includes('Could not find')) {
    const { error: fallbackError } = await admin.rpc('activate_gym_pro', rpcPayload);
    if (fallbackError) return fallbackError;
    await admin
      .from('gyms')
      .update({ auto_renew: true, updated_at: new Date().toISOString() })
      .eq('id', params.gymId);
    return null;
  }

  return activateError;
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
    const nowIso = new Date().toISOString();

    await admin
      .from('gyms')
      .update({
        plan_code: 'free',
        member_limit: 20,
        subscription_status: 'expired',
        auto_renew: false,
        updated_at: nowIso
      })
      .in('subscription_status', ['canceled', 'past_due'])
      .eq('auto_renew', false)
      .not('current_period_end', 'is', null)
      .lte('current_period_end', nowIso);

    const { data: claimedCharges, error } = await admin.rpc(
      'claim_due_toss_subscription_charges',
      {
        p_now: nowIso,
        p_limit: CLAIM_LIMIT,
        p_amount_krw: AMOUNT_KRW
      }
    );

    if (error) {
      const detail = [error.message, error.details, error.hint, error.code]
        .filter(Boolean)
        .join(' | ');
      if (String(error.message || '').includes('auto_renew') || error.code === '42703') {
        return jsonResponse({
          ok: false,
          error: 'DB column auto_renew missing. Run supabase/monthly_billing.sql in SQL Editor first.',
          detail
        }, 400);
      }
      return jsonResponse({ ok: false, error: detail || 'Query failed' }, 400);
    }

    const results: Array<Record<string, unknown>> = [];

    for (const claim of (claimedCharges || []) as ClaimedSubscriptionCharge[]) {
      const gymId = String(claim.gym_id || '');
      const ownerId = claim.user_id ? String(claim.user_id) : '';
      const billingKey = String(claim.billing_key_ref || '');
      const customerKey = String(claim.customer_key || '');
      const orderId = String(claim.order_id || '');
      const paymentAttemptId = String(claim.payment_attempt_id || '');
      const amountKrw = Number(claim.amount_krw || AMOUNT_KRW);
      let chargeSucceeded = false;

      try {
        if (!paymentAttemptId || !billingKey || !customerKey || !orderId) {
          throw new Error('Missing billing key');
        }

        if (!ownerId) throw new Error('Gym owner not found');

        const chargeRes = await fetch(`https://api.tosspayments.com/v1/billing/${billingKey}`, {
          method: 'POST',
          headers: {
            Authorization: tossAuthHeader(),
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            customerKey,
            amount: amountKrw,
            orderId,
            orderName: 're;member Pro 월간 자동결제'
          })
        });
        const charged = await chargeRes.json();
        if (!chargeRes.ok) {
          await updatePaymentAttempt(admin, paymentAttemptId, {
            status: 'charge_failed',
            activation_status: 'not_started',
            recovery_status: 'none',
            error_code: charged?.code || charged?.errorCode || null,
            error_message: charged?.message || charged?.errorMessage || 'Toss charge failed',
            provider_response: sanitizeProviderPayload(charged)
          });
          throw new Error(charged?.message || 'Toss charge failed');
        }

        const paymentKey = String(charged.paymentKey || orderId);
        chargeSucceeded = true;

        await updatePaymentAttempt(admin, paymentAttemptId, {
          status: 'activation_pending',
          activation_status: 'pending',
          recovery_status: 'none',
          payment_key: paymentKey,
          provider_response: sanitizeProviderPayload(charged)
        }, { throwOnError: true });

        await admin.from('checkout_sessions').insert({
          gym_id: gymId,
          user_id: ownerId,
          provider: 'toss',
          interval: 'monthly',
          amount_krw: amountKrw,
          amount_usd_cents: 0,
          currency: 'KRW',
          status: 'completed',
          order_id: orderId,
          provider_session_id: paymentKey,
          completed_at: new Date().toISOString(),
          raw: { mode: 'auto_renew', ...charged }
        });

        const activateError = await activateGymProWithFallback(admin, {
          gymId,
          customerKey,
          billingKey,
          paymentKey,
          charged
        });

        if (activateError) {
          await updatePaymentAttempt(admin, paymentAttemptId, {
            status: 'activation_failed',
            activation_status: 'failed',
            recovery_status: 'pending',
            error_message: activateError.message
          });
          throw activateError;
        }

        await updatePaymentAttempt(admin, paymentAttemptId, {
          status: 'completed',
          activation_status: 'succeeded',
          recovery_status: 'none',
          activated_at: new Date().toISOString(),
          error_code: null,
          error_message: null
        });

        results.push({ gymId, ok: true, orderId, paymentAttemptId });
      } catch (chargeError) {
        const message = chargeError instanceof Error ? chargeError.message : 'charge failed';
        if (!chargeSucceeded) {
          await updatePaymentAttempt(admin, paymentAttemptId, {
            status: 'charge_failed',
            activation_status: 'not_started',
            recovery_status: 'none',
            error_message: errorMessage(chargeError)
          });
        }
        await admin
          .from('gyms')
          .update({
            auto_renew: false,
            subscription_status: 'past_due',
            updated_at: new Date().toISOString()
          })
          .eq('id', gymId);
        results.push({ gymId, ok: false, orderId, paymentAttemptId, error: message });
      }
    }

    return jsonResponse({
      ok: true,
      checkedAt: nowIso,
      count: results.length,
      results
    });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : (error && typeof error === 'object' && 'message' in error)
        ? String((error as { message: unknown }).message)
        : JSON.stringify(error);
    return jsonResponse({ ok: false, error: message || 'Unknown error' }, 400);
  }
});
