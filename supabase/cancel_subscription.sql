-- =============================================================================
-- Cancel subscription + keep access until period end
-- Run in Supabase SQL Editor after billing.sql / checkout_sessions.sql
-- =============================================================================

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

  -- Allow controlled updates from security-definer RPCs (cancel/activate helpers).
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
  return new;
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

revoke all on function public.cancel_gym_subscription() from public;
grant execute on function public.cancel_gym_subscription() to authenticated;

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
    'billing_provider', v_gym.billing_provider
  );
end;
$$;
