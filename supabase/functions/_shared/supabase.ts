import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

export function getUserClient(jwt: string) {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const anon = Deno.env.get('SUPABASE_ANON_KEY') || '';
  return createClient(url, anon, {
    global: { headers: { Authorization: `Bearer ${jwt}` } }
  });
}

export function getAdminClient() {
  const url = Deno.env.get('SUPABASE_URL') || '';
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
  return createClient(url, service);
}

export async function requireUser(req: Request) {
  const authHeader = req.headers.get('Authorization') || '';
  const jwt = authHeader.replace(/^Bearer\s+/i, '').trim();
  if (!jwt) throw new Error('UNAUTHORIZED');

  const userClient = getUserClient(jwt);
  const { data, error } = await userClient.auth.getUser();
  if (error || !data?.user) throw new Error('UNAUTHORIZED');

  return { jwt, user: data.user, userClient };
}

export async function getGymIdForUser(admin: ReturnType<typeof getAdminClient>, userId: string) {
  const { data, error } = await admin
    .from('profiles')
    .select('gym_id')
    .eq('id', userId)
    .maybeSingle();

  if (error || !data?.gym_id) throw new Error('GYM_NOT_FOUND');
  return data.gym_id as string;
}
