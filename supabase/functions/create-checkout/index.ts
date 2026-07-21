// Example Supabase Edge Function: create-checkout
// Deploy with: supabase functions deploy create-checkout
// Set secrets: TOSS_SECRET_KEY (or STRIPE_SECRET_KEY), SERVICE_ROLE_KEY
//
// This is a design stub — wire your payment provider before production use.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const authHeader = req.headers.get('Authorization') || '';
  const jwt = authHeader.replace('Bearer ', '');
  if (!jwt) return new Response('Unauthorized', { status: 401 });

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: `Bearer ${jwt}` } }
  });
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: userData, error: userError } = await userClient.auth.getUser();
  if (userError || !userData?.user) {
    return new Response('Unauthorized', { status: 401 });
  }

  const body = await req.json();
  const interval = body.interval === 'yearly' ? 'yearly' : 'monthly';
  const amount = interval === 'yearly' ? 290000 : 29000;

  const { data: profile } = await admin
    .from('profiles')
    .select('gym_id')
    .eq('id', userData.user.id)
    .single();

  if (!profile?.gym_id) {
    return new Response('Gym not found', { status: 400 });
  }

  // TODO: create Toss billing / Stripe Checkout Session here.
  // Return a URL the browser can open.
  const checkoutUrl = body.successUrl || 'https://boxing-gym-manager.vercel.app/?billing=success';

  // Demo response shape expected by js/billing.js
  return Response.json({
    checkoutUrl,
    gymId: profile.gym_id,
    amount,
    interval,
    note: 'Replace this stub with real Toss/Stripe session creation.'
  });
});
