-- =============================================================================
-- Sweat Manager Billing / Subscription schema
-- Run AFTER supabase/schema.sql in Supabase SQL Editor.
-- =============================================================================

-- -----------------------------------------------------------------------------
-- 1) Plan fields on gyms
-- -----------------------------------------------------------------------------

alter table public.gyms
  add column if not exists plan_code text not null default 'free'
    check (plan_code in ('free', 'pro')),
  add column if not exists member_limit integer not null default 20
    check (member_limit = -1 or member_limit >= 0),
  add column if not exists subscription_status text not null default 'trialing'
    check (subscription_status in ('trialing', 'active', 'past_due', 'canceled', 'expired')),
  add column if not exists trial_ends_at timestamptz not null default (now() + interval '14 days'),
  add column if not exists current_period_end timestamptz,
  add column if not exists billing_provider text
    check (billing_provider is null or billing_provider in ('toss', 'stripe')),
  add column if not exists billing_customer_id text,
  add column if not exists billing_subscription_id text,
  add column if not exists updated_at timestamptz not null default now();

create index if not exists gyms_plan_code_idx on public.gyms (plan_code);
create index if not exists gyms_subscription_status_idx on public.gyms (subscription_status);

drop trigger if exists gyms_set_updated_at on public.gyms;
create trigger gyms_set_updated_at
before update on public.gyms
for each row
execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- 2) Subscription history (결제/웹훅 감사 로그)
-- -----------------------------------------------------------------------------

create table if not exists public.subscriptions (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  plan_code text not null check (plan_code in ('free', 'pro')),
  status text not null check (status in ('trialing', 'active', 'past_due', 'canceled', 'expired')),
  provider text check (provider is null or provider in ('toss', 'stripe', 'manual')),
  provider_ref text,
  amount_krw integer not null default 0 check (amount_krw >= 0),
  started_at timestamptz not null default now(),
  ends_at timestamptz,
  raw jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

create index if not exists subscriptions_gym_id_idx on public.subscriptions (gym_id);
create index if not exists subscriptions_gym_created_idx on public.subscriptions (gym_id, created_at desc);

alter table public.subscriptions enable row level security;

drop policy if exists "Gym can view own subscriptions" on public.subscriptions;
create policy "Gym can view own subscriptions"
on public.subscriptions
for select
to authenticated
using (gym_id = public.current_gym_id());

-- Inserts/updates come from service role (Edge Function / webhook), not the browser.

-- -----------------------------------------------------------------------------
-- 3) Effective plan helper
--    - trialing + trial not ended => pro (unlimited)
--    - active pro => unlimited
--    - otherwise free (member_limit)
-- -----------------------------------------------------------------------------

create or replace function public.gym_has_pro_access(p_gym public.gyms)
returns boolean
language sql
stable
as $$
  select
    case
      when p_gym.subscription_status = 'trialing'
           and p_gym.trial_ends_at > now() then true
      when p_gym.plan_code = 'pro'
           and p_gym.subscription_status = 'active' then true
      else false
    end
$$;

create or replace function public.gym_effective_member_limit(p_gym_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym from public.gyms where id = p_gym_id;
  if not found then
    return 0;
  end if;

  if public.gym_has_pro_access(v_gym) then
    return -1; -- unlimited
  end if;

  return coalesce(nullif(v_gym.member_limit, 0), 20);
end;
$$;

revoke all on function public.gym_effective_member_limit(uuid) from public;
grant execute on function public.gym_effective_member_limit(uuid) to authenticated;

create or replace function public.get_billing_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
  v_count integer;
  v_limit integer;
  v_pro boolean;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id();

  if not found then
    raise exception 'Gym not found';
  end if;

  select count(*) into v_count
  from public.members
  where gym_id = v_gym.id;

  v_pro := public.gym_has_pro_access(v_gym);
  v_limit := public.gym_effective_member_limit(v_gym.id);

  return jsonb_build_object(
    'gym_id', v_gym.id,
    'plan_code', v_gym.plan_code,
    'subscription_status', v_gym.subscription_status,
    'trial_ends_at', v_gym.trial_ends_at,
    'current_period_end', v_gym.current_period_end,
    'member_limit', v_limit,
    'member_count', v_count,
    'has_pro', v_pro,
    'can_add_member', (v_limit = -1 or v_count < v_limit),
    'billing_provider', v_gym.billing_provider
  );
end;
$$;

revoke all on function public.get_billing_summary() from public;
grant execute on function public.get_billing_summary() to authenticated;

-- -----------------------------------------------------------------------------
-- 4) Hard limit on member insert
-- -----------------------------------------------------------------------------

create or replace function public.enforce_member_limit()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limit integer;
  v_count integer;
begin
  v_limit := public.gym_effective_member_limit(new.gym_id);

  if v_limit = -1 then
    return new;
  end if;

  select count(*) into v_count
  from public.members
  where gym_id = new.gym_id;

  if v_count >= v_limit then
    raise exception 'MEMBER_LIMIT_REACHED:%', v_limit
      using errcode = 'P0001';
  end if;

  return new;
end;
$$;

drop trigger if exists members_enforce_limit on public.members;
create trigger members_enforce_limit
before insert on public.members
for each row
execute function public.enforce_member_limit();

-- -----------------------------------------------------------------------------
-- 5) New gyms start with 14-day Pro trial
-- -----------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym_id uuid;
  v_gym_name text;
  v_owner_name text;
  v_phone text;
begin
  v_gym_name := nullif(trim(coalesce(new.raw_user_meta_data->>'gym_name', '')), '');
  v_owner_name := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'owner_name', '')), ''), split_part(new.email, '@', 1));
  v_phone := coalesce(new.raw_user_meta_data->>'phone', '');

  if v_gym_name is null then
    v_gym_name := coalesce(v_owner_name, 'My Gym') || ' Gym';
  end if;

  insert into public.gyms (
    name,
    owner_name,
    phone,
    plan_code,
    member_limit,
    subscription_status,
    trial_ends_at
  )
  values (
    v_gym_name,
    v_owner_name,
    v_phone,
    'pro',
    20,
    'trialing',
    now() + interval '14 days'
  )
  returning id into v_gym_id;

  insert into public.profiles (id, gym_id, name)
  values (new.id, v_gym_id, v_owner_name);

  insert into public.subscriptions (gym_id, plan_code, status, provider, amount_krw, ends_at)
  values (v_gym_id, 'pro', 'trialing', 'manual', 0, now() + interval '14 days');

  return new;
end;
$$;

-- Existing gyms: keep free, but give a trial window if columns were just added
update public.gyms
set
  plan_code = coalesce(plan_code, 'free'),
  member_limit = coalesce(member_limit, 20),
  subscription_status = coalesce(subscription_status, 'trialing'),
  trial_ends_at = coalesce(trial_ends_at, now() + interval '14 days')
where true;

-- -----------------------------------------------------------------------------
-- 6) Prevent clients from self-upgrading plan fields
-- -----------------------------------------------------------------------------

create or replace function public.protect_gym_billing_columns()
returns trigger
language plpgsql
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  new.plan_code := old.plan_code;
  new.member_limit := old.member_limit;
  new.subscription_status := old.subscription_status;
  new.trial_ends_at := old.trial_ends_at;
  new.current_period_end := old.current_period_end;
  new.billing_provider := old.billing_provider;
  new.billing_customer_id := old.billing_customer_id;
  new.billing_subscription_id := old.billing_subscription_id;
  return new;
end;
$$;

drop trigger if exists gyms_protect_billing on public.gyms;
create trigger gyms_protect_billing
before update on public.gyms
for each row
execute function public.protect_gym_billing_columns();
