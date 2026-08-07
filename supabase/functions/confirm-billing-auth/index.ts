import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient, getGymIdForUser, requireUser } from '../_shared/supabase.ts';

const AMOUNT_KRW = 29000;

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  return `Basic ${btoa(`${secret}:`)}`;
}

function customerKeyForGym(gymId: string) {
  return `gym_${gymId.replace(/-/g, '')}`;
}

async function tossPost(path: string, body: Record<string, unknown>) {
  const res = await fetch(`https://api.tosspayments.com${path}`, {
    method: 'POST',
    headers: {
      Authorization: tossAuthHeader(),
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body)
  });
  const json = await res.json();
  if (!res.ok) {
    throw new Error(json?.message || json?.code || 'Toss API failed');
  }
  return json;
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return textResponse('Method not allowed', 405);
  }

  try {
    const { user } = await requireUser(req);
    const admin = getAdminClient();
    const gymId = await getGymIdForUser(admin, user.id);

    const body = await req.json();
    const authKey = String(body.authKey || '').trim();
    const customerKey = String(body.customerKey || '').trim();

    if (!authKey || !customerKey) {
      return textResponse('authKey and customerKey are required', 400);
    }

    const expected = customerKeyForGym(gymId);
    if (customerKey !== expected) {
      return textResponse('Invalid customerKey', 400);
    }

    // Idempotency: if already active with this customer key and auto_renew, skip re-issue
    const { data: gym } = await admin
      .from('gyms')
      .select('id, name, subscription_status, billing_customer_id, billing_subscription_id, auto_renew')
      .eq('id', gymId)
      .maybeSingle();

    if (
      gym?.subscription_status === 'active' &&
      gym?.auto_renew === true &&
      gym?.billing_customer_id === customerKey &&
      gym?.billing_subscription_id
    ) {
      return jsonResponse({
        ok: true,
        alreadyActive: true,
        gymId,
        interval: 'monthly'
      });
    }

    const issued = await tossPost('/v1/billing/authorizations/issue', {
      authKey,
      customerKey
    });

    const billingKey = String(issued.billingKey || '');
    if (!billingKey) {
      return textResponse('Failed to issue billing key', 502);
    }

    const orderId = `toss_bill_${Date.now()}_${crypto.randomUUID().replace(/-/g, '').slice(0, 12)}`;

    const { data: sessionRow, error: insertError } = await admin
      .from('checkout_sessions')
      .insert({
        gym_id: gymId,
        user_id: user.id,
        provider: 'toss',
        interval: 'monthly',
        amount_krw: AMOUNT_KRW,
        amount_usd_cents: 0,
        currency: 'KRW',
        status: 'pending',
        order_id: orderId,
        raw: {
          mode: 'billing_key',
          cardCompany: issued.card?.company || null,
          cardNumber: issued.card?.number || null
        }
      })
      .select('id')
      .single();

    if (insertError) {
      return textResponse(insertError.message, 500);
    }

    let charged;
    try {
      charged = await tossPost(`/v1/billing/${billingKey}`, {
        customerKey,
        amount: AMOUNT_KRW,
        orderId,
        orderName: 're;member Pro 월간 구독',
        customerEmail: user.email || undefined,
        customerName: gym?.name || undefined
      });
    } catch (chargeError) {
      await admin
        .from('checkout_sessions')
        .update({
          status: 'failed',
          raw: { error: String(chargeError) }
        })
        .eq('id', sessionRow.id);
      throw chargeError;
    }

    const paymentKey = String(charged.paymentKey || orderId);

    const { error: activateError } = await admin.rpc('activate_gym_pro', {
      p_gym_id: gymId,
      p_provider: 'toss',
      p_interval: 'monthly',
      p_amount_krw: AMOUNT_KRW,
      p_customer_id: customerKey,
      p_subscription_id: billingKey,
      p_provider_ref: paymentKey,
      p_raw: charged,
      p_auto_renew: true
    });

    if (activateError) {
      // Older SQL without p_auto_renew — fall back then set auto_renew
      if (String(activateError.message || '').includes('p_auto_renew') ||
          String(activateError.message || '').includes('Could not find')) {
        const { error: fallbackError } = await admin.rpc('activate_gym_pro', {
          p_gym_id: gymId,
          p_provider: 'toss',
          p_interval: 'monthly',
          p_amount_krw: AMOUNT_KRW,
          p_customer_id: customerKey,
          p_subscription_id: billingKey,
          p_provider_ref: paymentKey,
          p_raw: charged
        });
        if (fallbackError) return textResponse(fallbackError.message, 500);
        await admin
          .from('gyms')
          .update({ auto_renew: true, updated_at: new Date().toISOString() })
          .eq('id', gymId);
      } else {
        return textResponse(activateError.message, 500);
      }
    }

    await admin
      .from('checkout_sessions')
      .update({
        status: 'completed',
        provider_session_id: paymentKey,
        completed_at: new Date().toISOString(),
        raw: { ...charged, billingKeyIssued: true }
      })
      .eq('id', sessionRow.id);

    return jsonResponse({
      ok: true,
      provider: 'toss',
      gymId,
      orderId,
      paymentKey,
      interval: 'monthly',
      billingKeyIssued: true
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === 'UNAUTHORIZED' ? 401 : 400;
    return textResponse(message, status);
  }
});
