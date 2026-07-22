import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient, getGymIdForUser, requireUser } from '../_shared/supabase.ts';

type Interval = 'monthly' | 'yearly';
type Provider = 'toss' | 'stripe';

const PRICE_KRW = {
  monthly: 29000,
  yearly: 290000
} as const;

const PRICE_USD_CENTS = {
  monthly: 2900, // $29.00 fallback if Stripe Price IDs are not set
  yearly: 29000 // $290.00
} as const;

function makeOrderId(provider: Provider) {
  const rand = crypto.randomUUID().replace(/-/g, '').slice(0, 16);
  return `${provider}_${Date.now()}_${rand}`;
}

async function createStripeCheckout(params: {
  admin: ReturnType<typeof getAdminClient>;
  gymId: string;
  userId: string;
  email: string;
  interval: Interval;
  successUrl: string;
  failUrl: string;
}) {
  const secret = Deno.env.get('STRIPE_SECRET_KEY');
  if (!secret) throw new Error('STRIPE_SECRET_KEY is missing');

  const priceMonthly = Deno.env.get('STRIPE_PRICE_MONTHLY') || '';
  const priceYearly = Deno.env.get('STRIPE_PRICE_YEARLY') || '';
  const priceId = params.interval === 'yearly' ? priceYearly : priceMonthly;

  const orderId = makeOrderId('stripe');
  const amountKrw = PRICE_KRW[params.interval];
  const amountUsd = PRICE_USD_CENTS[params.interval];

  const { data: sessionRow, error: insertError } = await params.admin
    .from('checkout_sessions')
    .insert({
      gym_id: params.gymId,
      user_id: params.userId,
      provider: 'stripe',
      interval: params.interval,
      amount_krw: amountKrw,
      amount_usd_cents: amountUsd,
      currency: priceId ? 'usd' : 'usd',
      status: 'pending',
      order_id: orderId,
      success_url: params.successUrl,
      fail_url: params.failUrl
    })
    .select('id')
    .single();

  if (insertError) throw new Error(insertError.message);

  const form = new URLSearchParams();
  form.set('mode', 'subscription');
  form.set('success_url', `${params.successUrl}${params.successUrl.includes('?') ? '&' : '?'}session_id={CHECKOUT_SESSION_ID}&provider=stripe`);
  form.set('cancel_url', `${params.failUrl}${params.failUrl.includes('?') ? '&' : '?'}provider=stripe`);
  form.set('client_reference_id', params.gymId);
  form.set('customer_email', params.email);
  form.set('metadata[gym_id]', params.gymId);
  form.set('metadata[user_id]', params.userId);
  form.set('metadata[order_id]', orderId);
  form.set('metadata[interval]', params.interval);
  form.set('subscription_data[metadata][gym_id]', params.gymId);
  form.set('subscription_data[metadata][order_id]', orderId);
  form.set('subscription_data[metadata][interval]', params.interval);

  if (priceId) {
    form.set('line_items[0][price]', priceId);
    form.set('line_items[0][quantity]', '1');
  } else {
    // Fallback one-off style price_data subscription
    form.set('line_items[0][price_data][currency]', 'usd');
    form.set('line_items[0][price_data][unit_amount]', String(amountUsd));
    form.set('line_items[0][price_data][recurring][interval]', params.interval === 'yearly' ? 'year' : 'month');
    form.set('line_items[0][price_data][product_data][name]', 'Sweat Manager Pro');
    form.set('line_items[0][quantity]', '1');
  }

  const stripeRes = await fetch('https://api.stripe.com/v1/checkout/sessions', {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${secret}`,
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: form
  });

  const stripeJson = await stripeRes.json();
  if (!stripeRes.ok) {
    throw new Error(stripeJson?.error?.message || 'Stripe checkout create failed');
  }

  await params.admin
    .from('checkout_sessions')
    .update({
      provider_session_id: stripeJson.id,
      raw: stripeJson
    })
    .eq('id', sessionRow.id);

  return {
    mode: 'redirect',
    provider: 'stripe',
    checkoutUrl: stripeJson.url,
    orderId,
    sessionId: stripeJson.id
  };
}

async function createTossCheckout(params: {
  admin: ReturnType<typeof getAdminClient>;
  gymId: string;
  userId: string;
  email: string;
  interval: Interval;
  successUrl: string;
  failUrl: string;
}) {
  const clientKey = Deno.env.get('TOSS_CLIENT_KEY') || Deno.env.get('TOSS_WIDGET_CLIENT_KEY') || '';
  if (!clientKey) throw new Error('TOSS_CLIENT_KEY is missing');

  const orderId = makeOrderId('toss');
  const amountKrw = PRICE_KRW[params.interval];
  const orderName = params.interval === 'yearly'
    ? 'Sweat Manager Pro (Yearly)'
    : 'Sweat Manager Pro (Monthly)';

  const { error: insertError } = await params.admin
    .from('checkout_sessions')
    .insert({
      gym_id: params.gymId,
      user_id: params.userId,
      provider: 'toss',
      interval: params.interval,
      amount_krw: amountKrw,
      amount_usd_cents: 0,
      currency: 'KRW',
      status: 'pending',
      order_id: orderId,
      success_url: params.successUrl,
      fail_url: params.failUrl,
      raw: { orderName }
    });

  if (insertError) throw new Error(insertError.message);

  const successUrl = `${params.successUrl}${params.successUrl.includes('?') ? '&' : '?'}provider=toss&orderId=${encodeURIComponent(orderId)}`;
  const failUrl = `${params.failUrl}${params.failUrl.includes('?') ? '&' : '?'}provider=toss&orderId=${encodeURIComponent(orderId)}`;

  // Frontend opens Toss payment widget / requestPayment with these values.
  return {
    mode: 'toss_widget',
    provider: 'toss',
    clientKey,
    orderId,
    orderName,
    amount: amountKrw,
    currency: 'KRW',
    customerKey: params.userId,
    customerEmail: params.email,
    successUrl,
    failUrl,
    interval: params.interval
  };
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
    const interval: Interval = body.interval === 'yearly' ? 'yearly' : 'monthly';
    const provider: Provider = body.provider === 'stripe' ? 'stripe' : 'toss';
    const origin = Deno.env.get('APP_URL') || 'https://boxing-gym-manager.vercel.app';
    const successUrl = body.successUrl || `${origin}/?billing=success`;
    const failUrl = body.failUrl || `${origin}/?billing=fail`;

    const payload = provider === 'stripe'
      ? await createStripeCheckout({
        admin,
        gymId,
        userId: user.id,
        email: user.email || '',
        interval,
        successUrl,
        failUrl
      })
      : await createTossCheckout({
        admin,
        gymId,
        userId: user.id,
        email: user.email || '',
        interval,
        successUrl,
        failUrl
      });

    return jsonResponse(payload);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === 'UNAUTHORIZED' ? 401 : 400;
    return textResponse(message, status);
  }
});
