import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';
import {
  type AdminClientLike,
  type ClaimedSubscriptionCharge,
  processClaimedSubscriptionCharge
} from './subscription_charge.ts';

const AMOUNT_KRW = 10000;
const CLAIM_LIMIT = 50;

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

function errorMessage(error: unknown) {
  return error instanceof Error ? error.message : String(error);
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
const { data: trialCleanup, error: trialCleanupError } = await admin.rpc(
  'expire_unpaid_trial_gyms',
  {
    p_now: nowIso,
    p_limit: 500
  }
);

if (trialCleanupError) {
  console.error('UNPAID_TRIAL_CLEANUP_FAILED', {
    error: trialCleanupError.message,
    code: trialCleanupError.code
  });
} else {
  console.log('UNPAID_TRIAL_CLEANUP_COMPLETED', trialCleanup);
}
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
      const result = await processClaimedSubscriptionCharge(
        admin as unknown as AdminClientLike,
        claim,
        {
          tossSecret: Deno.env.get('TOSS_SECRET_KEY') || '',
          fetchImpl: fetch
        }
      );
      results.push(result);
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
