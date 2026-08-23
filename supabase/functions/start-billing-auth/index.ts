import { corsHeaders, jsonResponse, textResponse } from '../_shared/cors.ts';
import { getAdminClient, getGymIdForUser, requireUser } from '../_shared/supabase.ts';

function customerKeyForGym(gymId: string) {
  // Toss: 2~300 chars, alphanumeric + some symbols. Stable per gym.
  return `gym_${gymId.replace(/-/g, '')}`;
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

    const clientKey = Deno.env.get('TOSS_CLIENT_KEY') || Deno.env.get('TOSS_WIDGET_CLIENT_KEY') || '';
    if (!clientKey) throw new Error('TOSS_CLIENT_KEY is missing');

    const origin = Deno.env.get('APP_URL') || 'https://boxing-gym-manager.vercel.app';
    const body = await req.json().catch(() => ({}));
    const successBase = String(body.successUrl || `${origin}/?billing=success`);
    const failBase = String(body.failUrl || `${origin}/?billing=fail`);

    const customerKey = customerKeyForGym(gymId);
    const successUrl = `${successBase}${successBase.includes('?') ? '&' : '?'}provider=toss&mode=billing`;
    const failUrl = `${failBase}${failBase.includes('?') ? '&' : '?'}provider=toss&mode=billing`;

    const { data: gym } = await admin
      .from('gyms')
      .select('name')
      .eq('id', gymId)
      .maybeSingle();

    return jsonResponse({
      mode: 'toss_billing_auth',
      provider: 'toss',
      clientKey,
      customerKey,
      customerEmail: user.email || '',
      customerName: gym?.name || user.email || 're;member',
      successUrl,
      failUrl,
      amount: 10000,
      interval: 'monthly'
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const status = message === 'UNAUTHORIZED' ? 401 : 400;
    return textResponse(message, status);
  }
});
