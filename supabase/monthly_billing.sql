-- =============================================================================
-- Monthly auto-renew (Netflix-style) fields
-- Run after cancel_subscription.sql
-- =============================================================================

alter table public.gyms
  add column if not exists auto_renew boolean not null default false;

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
      when p_gym.plan_code = 'pro'
           and p_gym.subscription_status = 'canceled'
           and p_gym.current_period_end is not null
           and p_gym.current_period_end > now() then true
      else false
    end
$$;

create or replace function public.protect_gym_billing_columns()
returns trigger
language plpgsql
as $$
begin
  if auth.role() = 'service_role' then
    return new;
  end if;

  if current_setting('app.allow_billing_update', true) = '1' then
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
  new.auto_renew := old.auto_renew;
  return new;
end;
$$;

create or replace function public.activate_gym_pro(
  p_gym_id uuid,
  p_provider text,
  p_interval text,
  p_amount_krw integer default 0,
  p_customer_id text default null,
  p_subscription_id text default null,
  p_provider_ref text default null,
  p_raw jsonb default '{}'::jsonb,
  p_auto_renew boolean default true
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

  perform set_config('app.allow_billing_update', '1', true);

  update public.gyms
  set
    plan_code = 'pro',
    member_limit = -1,
    subscription_status = 'active',
    current_period_end = v_ends,
    billing_provider = p_provider,
    billing_customer_id = coalesce(p_customer_id, billing_customer_id),
    billing_subscription_id = coalesce(p_subscription_id, billing_subscription_id),
    auto_renew = coalesce(p_auto_renew, true),
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

revoke all on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb, boolean) from public;
grant execute on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb, boolean) to service_role;

-- Keep backward-compatible 8-arg wrapper
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
begin
  perform public.activate_gym_pro(
    p_gym_id,
    p_provider,
    p_interval,
    p_amount_krw,
    p_customer_id,
    p_subscription_id,
    p_provider_ref,
    p_raw,
    true
  );
end;
$$;

create or replace function public.cancel_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id()
  for update;

  if not found then
    raise exception 'Gym not found';
  end if;

  if v_gym.subscription_status = 'canceled' then
    return jsonb_build_object(
      'ok', true,
      'already_canceled', true,
      'current_period_end', v_gym.current_period_end
    );
  end if;

  if v_gym.subscription_status not in ('active', 'past_due') then
    raise exception 'NOTHING_TO_CANCEL';
  end if;

  perform set_config('app.allow_billing_update', '1', true);

  update public.gyms
  set
    subscription_status = 'canceled',
    auto_renew = false,
    updated_at = now()
  where id = v_gym.id;

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
    v_gym.id,
    'pro',
    'canceled',
    coalesce(v_gym.billing_provider, 'toss'),
    v_gym.billing_subscription_id,
    0,
    now(),
    v_gym.current_period_end,
    jsonb_build_object('canceled_by', auth.uid(), 'reason', 'user_cancel')
  );

  return jsonb_build_object(
    'ok', true,
    'already_canceled', false,
    'current_period_end', v_gym.current_period_end
  );
end;
$$;

create or replace function public.resume_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id()
  for update;

  if not found then
    raise exception 'Gym not found';
  end if;

  if v_gym.subscription_status <> 'canceled'
     or v_gym.current_period_end is null
     or v_gym.current_period_end <= now() then
    raise exception 'NOTHING_TO_RESUME';
  end if;

  if v_gym.billing_subscription_id is null
     or v_gym.billing_customer_id is null then
    raise exception 'BILLING_KEY_NOT_FOUND';
  end if;

  perform set_config('app.allow_billing_update', '1', true);

  update public.gyms
  set
    plan_code = 'pro',
    member_limit = -1,
    subscription_status = 'active',
    auto_renew = true,
    updated_at = now()
  where id = v_gym.id;

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
    v_gym.id,
    'pro',
    'active',
    coalesce(v_gym.billing_provider, 'toss'),
    v_gym.billing_subscription_id,
    0,
    now(),
    v_gym.current_period_end,
    jsonb_build_object('resumed_by', auth.uid(), 'reason', 'user_resume')
  );

  return jsonb_build_object(
    'ok', true,
    'current_period_end', v_gym.current_period_end
  );
end;
$$;

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
    'can_cancel', (v_gym.subscription_status in ('active', 'past_due')),
    'can_resume', (
      v_gym.subscription_status = 'canceled'
      and v_gym.current_period_end is not null
      and v_gym.current_period_end > now()
      and v_gym.billing_subscription_id is not null
      and v_gym.billing_customer_id is not null
    ),
    'auto_renew', coalesce(v_gym.auto_renew, false),
    'billing_provider', v_gym.billing_provider
  );
end;
$$;

revoke all on function public.resume_gym_subscription() from public;
grant execute on function public.resume_gym_subscription() to authenticated;
