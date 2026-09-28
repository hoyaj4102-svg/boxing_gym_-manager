import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

const AMOUNT_KRW = 10000;

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

function nextMonthlyPeriodEnd() {
  const date = new Date();
  date.setDate(date.getDate() + 30);
  return date.toISOString();
}

async function updatePaymentAttempt(
  admin: ReturnType<typeof getAdminClient>,
  attemptId: string | null,
  values: Record<string, unknown>
) {
  if (!attemptId) return;
  const { error } = await admin
    .from('payment_attempts')
    .update(values)
    .eq('id', attemptId);
  if (error) {
    console.error('PAYMENT_ATTEMPT_UPDATE_FAILED', {
      attemptId,
      error: error.message
    });
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

    const { data: gyms, error } = await admin
      .from('gyms')
      .select(
        'id, name, subscription_status, auto_renew, billing_provider, billing_customer_id, billing_subscription_id, current_period_end'
      )
      .eq('billing_provider', 'toss')
      .eq('auto_renew', true)
      .eq('subscription_status', 'active')
      .not('billing_subscription_id', 'is', null)
      .lte('current_period_end', nowIso);

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

    for (const gym of gyms || []) {
      const billingKey = String(gym.billing_subscription_id || '');
      const customerKey = String(gym.billing_customer_id || '');
      const orderId = `toss_renew_${Date.now()}_${crypto.randomUUID().replace(/-/g, '').slice(0, 10)}`;
      let paymentAttemptId: string | null = null;
      let chargeSucceeded = false;

      try {
        if (!billingKey || !customerKey) {
          throw new Error('Missing billing key');
        }

        const { data: owner } = await admin
          .from('profiles')
          .select('id')
          .eq('gym_id', gym.id)
          .limit(1)
          .maybeSingle();

        if (!owner?.id) throw new Error('Gym owner not found');

        const { data: paymentAttempt, error: attemptError } = await admin
          .from('payment_attempts')
          .insert({
            gym_id: gym.id,
            user_id: owner.id,
            provider: 'toss',
            payment_type: 'auto_renewal',
            billing_interval: 'monthly',
            amount_krw: AMOUNT_KRW,
            currency: 'KRW',
            order_id: orderId,
            customer_key: customerKey,
            billing_key_ref: billingKey,
            target_period_start: gym.current_period_end,
            target_period_end: nextMonthlyPeriodEnd(),
            status: 'initiated',
            activation_status: 'not_started',
            recovery_status: 'none',
            provider_response: { mode: 'auto_renew_start' }
          })
          .select('id')
          .single();

        if (attemptError) throw attemptError;
        paymentAttemptId = paymentAttempt.id;

        const chargeRes = await fetch(`https://api.tosspayments.com/v1/billing/${billingKey}`, {
          method: 'POST',
          headers: {
            Authorization: tossAuthHeader(),
            'Content-Type': 'application/json'
          },
          body: JSON.stringify({
            customerKey,
            amount: AMOUNT_KRW,
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
        });

        await admin.from('checkout_sessions').insert({
          gym_id: gym.id,
          user_id: owner.id,
          provider: 'toss',
          interval: 'monthly',
          amount_krw: AMOUNT_KRW,
          amount_usd_cents: 0,
          currency: 'KRW',
          status: 'completed',
          order_id: orderId,
          provider_session_id: paymentKey,
          completed_at: new Date().toISOString(),
          raw: { mode: 'auto_renew', ...charged }
        });

        const activateError = await activateGymProWithFallback(admin, {
          gymId: gym.id,
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

        results.push({ gymId: gym.id, ok: true, orderId });
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
          .eq('id', gym.id);
        results.push({ gymId: gym.id, ok: false, error: message });
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
