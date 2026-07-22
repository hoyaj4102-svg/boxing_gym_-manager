-- =============================================================================
-- Checkout session tracking for Toss / Stripe
-- Run after supabase/billing.sql
-- =============================================================================

create table if not exists public.checkout_sessions (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  provider text not null check (provider in ('toss', 'stripe')),
  interval text not null check (interval in ('monthly', 'yearly')),
  amount_krw integer not null default 0 check (amount_krw >= 0),
  amount_usd_cents integer not null default 0 check (amount_usd_cents >= 0),
  currency text not null default 'KRW',
  status text not null default 'pending'
    check (status in ('pending', 'completed', 'failed', 'canceled', 'expired')),
  order_id text not null unique,
  provider_session_id text,
  success_url text,
  fail_url text,
  raw jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  completed_at timestamptz
);

create index if not exists checkout_sessions_gym_id_idx
  on public.checkout_sessions (gym_id);
create index if not exists checkout_sessions_user_id_idx
  on public.checkout_sessions (user_id);
create index if not exists checkout_sessions_status_idx
  on public.checkout_sessions (status);

alter table public.checkout_sessions enable row level security;

drop policy if exists "Users can view own checkout sessions" on public.checkout_sessions;
create policy "Users can view own checkout sessions"
on public.checkout_sessions
for select
to authenticated
using (
  user_id = auth.uid()
  and gym_id = public.current_gym_id()
);

-- Writes are done by Edge Functions with service role.

create or replace function public.activate_gym_pro(
  p_gym_id uuid,
  p_provider text,
  p_interval text,
  p_amount_krw integer default 0,
  p_customer_id text default null,
  p_subscription_id text default null,
  p_provider_ref text default null,
  p_raw jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ends timestamptz;
begin
  if p_interval = 'yearly' then
    v_ends := now() + interval '365 days';
  else
    v_ends := now() + interval '30 days';
  end if;

  update public.gyms
  set
    plan_code = 'pro',
    member_limit = -1,
    subscription_status = 'active',
    current_period_end = v_ends,
    billing_provider = p_provider,
    billing_customer_id = coalesce(p_customer_id, billing_customer_id),
    billing_subscription_id = coalesce(p_subscription_id, billing_subscription_id),
    updated_at = now()
  where id = p_gym_id;

  insert into public.subscriptions (
    gym_id,
    plan_code,
    status,
    provider,
    provider_ref,
    amount_krw,
    started_at,
    ends_at,
    raw
  )
  values (
    p_gym_id,
    'pro',
    'active',
    p_provider,
    coalesce(p_provider_ref, p_subscription_id),
    coalesce(p_amount_krw, 0),
    now(),
    v_ends,
    coalesce(p_raw, '{}'::jsonb)
  );
end;
$$;

revoke all on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb) from public;
grant execute on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb) to service_role;
-- Only service role should call this from Edge Functions.
