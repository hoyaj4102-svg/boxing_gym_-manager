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
          throw new Error(charged?.message || 'Toss charge failed');
        }

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
          provider_session_id: String(charged.paymentKey || orderId),
          completed_at: new Date().toISOString(),
          raw: { mode: 'auto_renew', ...charged }
        });

        const { error: activateError } = await admin.rpc('activate_gym_pro', {
          p_gym_id: gym.id,
          p_provider: 'toss',
          p_interval: 'monthly',
          p_amount_krw: AMOUNT_KRW,
          p_customer_id: customerKey,
          p_subscription_id: billingKey,
          p_provider_ref: String(charged.paymentKey || orderId),
          p_raw: charged,
          p_auto_renew: true
        });

        if (activateError) {
          const { error: fallbackError } = await admin.rpc('activate_gym_pro', {
            p_gym_id: gym.id,
            p_provider: 'toss',
            p_interval: 'monthly',
            p_amount_krw: AMOUNT_KRW,
            p_customer_id: customerKey,
            p_subscription_id: billingKey,
            p_provider_ref: String(charged.paymentKey || orderId),
            p_raw: charged
          });
          if (fallbackError) throw fallbackError;
          await admin
            .from('gyms')
            .update({ auto_renew: true, updated_at: new Date().toISOString() })
            .eq('id', gym.id);
        }

        results.push({ gymId: gym.id, ok: true, orderId });
      } catch (chargeError) {
        const message = chargeError instanceof Error ? chargeError.message : 'charge failed';
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
