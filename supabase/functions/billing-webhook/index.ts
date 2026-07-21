// Example webhook Edge Function (Toss/Stripe -> activate Pro)
// Verify provider signature, then update gyms + insert subscriptions with service role.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  // TODO: verify Toss/Stripe webhook signature before trusting the body.
  const event = await req.json();
  const gymId = event.gym_id || event.metadata?.gym_id;
  if (!gymId) return new Response('gym_id required', { status: 400 });

  const admin = createClient(
    Deno.env.get('SUPABASE_URL'),
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  );

  const periodEnd = event.current_period_end
    ? new Date(event.current_period_end)
    : new Date(Date.now() + 30 * 24 * 60 * 60 * 1000);

  const { error: gymError } = await admin
    .from('gyms')
    .update({
      plan_code: 'pro',
      member_limit: -1,
      subscription_status: 'active',
      current_period_end: periodEnd.toISOString(),
      billing_provider: event.provider || 'toss',
      billing_customer_id: event.customer_id || null,
      billing_subscription_id: event.subscription_id || null
    })
    .eq('id', gymId);

  if (gymError) {
    return new Response(gymError.message, { status: 500 });
  }

  await admin.from('subscriptions').insert({
    gym_id: gymId,
    plan_code: 'pro',
    status: 'active',
    provider: event.provider || 'toss',
    provider_ref: event.subscription_id || event.payment_key || null,
    amount_krw: event.amount_krw || 29000,
    ends_at: periodEnd.toISOString(),
    raw: event
  });

  return Response.json({ ok: true });
});
