import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient, requireUser } from '../_shared/supabase.ts';

function tossAuthHeader() {
  const secret = Deno.env.get('TOSS_SECRET_KEY') || '';
  if (!secret) throw new Error('TOSS_SECRET_KEY is missing');
  const encoded = btoa(`${secret}:`);
  return `Basic ${encoded}`;
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
    const body = await req.json();

    const paymentKey = String(body.paymentKey || '');
    const orderId = String(body.orderId || '');
    const amount = Number(body.amount);

    if (!paymentKey || !orderId || !Number.isFinite(amount)) {
      return textResponse('paymentKey, orderId, amount are required', 400);
    }

    const { data: session, error: sessionError } = await admin
      .from('checkout_sessions')
      .select('*')
      .eq('order_id', orderId)
      .eq('provider', 'toss')
      .maybeSingle();

    if (sessionError || !session) {
      return textResponse('Checkout session not found', 404);
    }

    if (session.user_id !== user.id) {
      return textResponse('Forbidden', 403);
    }

    if (session.status === 'completed') {
      return jsonResponse({ ok: true, alreadyCompleted: true, gymId: session.gym_id });
    }

    if (Number(session.amount_krw) !== amount) {
      return textResponse('Amount mismatch', 400);
    }

    const confirmRes = await fetch('https://api.tosspayments.com/v1/payments/confirm', {
      method: 'POST',
      headers: {
        Authorization: tossAuthHeader(),
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ paymentKey, orderId, amount })
    });

    const confirmJson = await confirmRes.json();
    if (!confirmRes.ok) {
      await admin
        .from('checkout_sessions')
        .update({ status: 'failed', raw: confirmJson })
        .eq('id', session.id);
      return textResponse(confirmJson?.message || 'Toss confirm failed', 400);
    }

    const { error: activateError } = await admin.rpc('activate_gym_pro', {
      p_gym_id: session.gym_id,
      p_provider: 'toss',
      p_interval: session.interval,
      p_amount_krw: session.amount_krw,
      p_customer_id: confirmJson?.customerKey || user.id,
      p_subscription_id: confirmJson?.paymentKey || paymentKey,
      p_provider_ref: confirmJson?.paymentKey || paymentKey,
      p_raw: confirmJson
    });

    if (activateError) {
      return textResponse(activateError.message, 500);
    }

    await admin
      .from('checkout_sessions')
      .update({
        status: 'completed',
        provider_session_id: paymentKey,
        completed_at: new Date().toISOString(),
        raw: confirmJson
      })
      .eq('id', session.id);

    return jsonResponse({
      ok: true,
      provider: 'toss',
      gymId: session.gym_id,
      interval: session.interval
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === 'UNAUTHORIZED' ? 401 : 400;
    return textResponse(message, status);
  }
});
