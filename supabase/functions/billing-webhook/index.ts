import Stripe from 'https://esm.sh/stripe@14.25.0?target=deno';
import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient } from '../_shared/supabase.ts';

async function activateFromStripeSession(admin: ReturnType<typeof getAdminClient>, session: Stripe.Checkout.Session) {
  const gymId = session.metadata?.gym_id || session.client_reference_id;
  const orderId = session.metadata?.order_id;
  const interval = session.metadata?.interval === 'yearly' ? 'yearly' : 'monthly';

  if (!gymId) throw new Error('gym_id missing in Stripe session metadata');

  if (orderId) {
    const { data: existing } = await admin
      .from('checkout_sessions')
      .select('id, status, amount_krw')
      .eq('order_id', orderId)
      .maybeSingle();

    if (existing?.status === 'completed') {
      return { ok: true, alreadyCompleted: true };
    }
  }

  const amountKrw = interval === 'yearly' ? 290000 : 29000;
  const customerId = typeof session.customer === 'string' ? session.customer : session.customer?.id || null;
  const subscriptionId = typeof session.subscription === 'string'
    ? session.subscription
    : session.subscription?.id || null;

  const { error } = await admin.rpc('activate_gym_pro', {
    p_gym_id: gymId,
    p_provider: 'stripe',
    p_interval: interval,
    p_amount_krw: amountKrw,
    p_customer_id: customerId,
    p_subscription_id: subscriptionId,
    p_provider_ref: session.id,
    p_raw: session
  });

  if (error) throw new Error(error.message);

  if (orderId) {
    await admin
      .from('checkout_sessions')
      .update({
        status: 'completed',
        provider_session_id: session.id,
        completed_at: new Date().toISOString(),
        raw: session
      })
      .eq('order_id', orderId);
  }

  return { ok: true };
}

async function markPastDue(admin: ReturnType<typeof getAdminClient>, subscription: Stripe.Subscription) {
  const gymId = subscription.metadata?.gym_id;
  if (!gymId) return;

  await admin
    .from('gyms')
    .update({
      subscription_status: 'past_due',
      billing_subscription_id: subscription.id
    })
    .eq('id', gymId);
}

async function markCanceled(admin: ReturnType<typeof getAdminClient>, subscription: Stripe.Subscription) {
  const gymId = subscription.metadata?.gym_id;
  if (!gymId) return;

  await admin
    .from('gyms')
    .update({
      plan_code: 'free',
      member_limit: 20,
      subscription_status: 'canceled',
      billing_subscription_id: subscription.id
    })
    .eq('id', gymId);

  await admin.from('subscriptions').insert({
    gym_id: gymId,
    plan_code: 'free',
    status: 'canceled',
    provider: 'stripe',
    provider_ref: subscription.id,
    amount_krw: 0,
    raw: subscription
  });
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return textResponse('Method not allowed', 405);
  }

  const providerHint = new URL(req.url).searchParams.get('provider') || 'stripe';

  try {
    const admin = getAdminClient();

    if (providerHint === 'toss') {
      // Toss usually confirms via confirm-toss-payment.
      // Optional webhook passthrough can be added later.
      return jsonResponse({ ok: true, ignored: true, reason: 'Use confirm-toss-payment for Toss' });
    }

    const stripeSecret = Deno.env.get('STRIPE_SECRET_KEY') || '';
    const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET') || '';
    if (!stripeSecret || !webhookSecret) {
      return textResponse('Stripe secrets missing', 500);
    }

    const stripe = new Stripe(stripeSecret, {
      apiVersion: '2023-10-16',
      httpClient: Stripe.createFetchHttpClient()
    });

    const signature = req.headers.get('stripe-signature');
    if (!signature) return textResponse('Missing stripe-signature', 400);

    const body = await req.text();
    const event = await stripe.webhooks.constructEventAsync(
      body,
      signature,
      webhookSecret,
      undefined,
      Stripe.createSubtleCryptoProvider()
    );

    switch (event.type) {
      case 'checkout.session.completed': {
        const session = event.data.object as Stripe.Checkout.Session;
        if (session.mode === 'subscription' || session.payment_status === 'paid') {
          await activateFromStripeSession(admin, session);
        }
        break;
      }
      case 'invoice.paid': {
        const invoice = event.data.object as Stripe.Invoice;
        const subscriptionId = typeof invoice.subscription === 'string'
          ? invoice.subscription
          : invoice.subscription?.id;
        if (subscriptionId) {
          const subscription = await stripe.subscriptions.retrieve(subscriptionId);
          const gymId = subscription.metadata?.gym_id;
          if (gymId) {
            await admin
              .from('gyms')
              .update({
                plan_code: 'pro',
                member_limit: -1,
                subscription_status: 'active',
                current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
                billing_provider: 'stripe',
                billing_subscription_id: subscription.id
              })
              .eq('id', gymId);
          }
        }
        break;
      }
      case 'invoice.payment_failed': {
        const invoice = event.data.object as Stripe.Invoice;
        const subscriptionId = typeof invoice.subscription === 'string'
          ? invoice.subscription
          : invoice.subscription?.id;
        if (subscriptionId) {
          const subscription = await stripe.subscriptions.retrieve(subscriptionId);
          await markPastDue(admin, subscription);
        }
        break;
      }
      case 'customer.subscription.deleted': {
        const subscription = event.data.object as Stripe.Subscription;
        await markCanceled(admin, subscription);
        break;
      }
      default:
        break;
    }

    return jsonResponse({ received: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    return textResponse(message, 400);
  }
});
