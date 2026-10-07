-- =============================================================================
-- P1-5 calendar-month billing periods
--
-- Purpose:
-- - Monthly billing uses PostgreSQL calendar-month arithmetic, not fixed 30 days.
-- - Existing customer data is not updated by this script.
-- - payment_attempt target_period_start/end are the source of truth for
--   activation and recovery.
--
-- Run after:
--   billing.sql
--   checkout_sessions.sql
--   monthly_billing.sql
--   payment_attempts.sql
--   p0_2_payment_claim.sql
-- =============================================================================

create or replace function public.billing_period_end(
  p_period_start timestamptz,
  p_interval text
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if p_period_start is null then
    raise exception 'PERIOD_START_REQUIRED';
  end if;

  if p_interval = 'monthly' then
    return p_period_start + interval '1 month';
  end if;

  if p_interval = 'yearly' then
    -- Keep the existing yearly semantics unchanged for P1-5.
    return p_period_start + interval '365 days';
  end if;

  raise exception 'UNSUPPORTED_BILLING_INTERVAL:%', p_interval;
end;
$$;

revoke all on function public.billing_period_end(timestamptz, text) from public;
revoke all on function public.billing_period_end(timestamptz, text) from anon, authenticated;
grant execute on function public.billing_period_end(timestamptz, text) to service_role;

create or replace function public.billing_period_bounds(
  p_interval text default 'monthly',
  p_period_start timestamptz default null
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_period_start timestamptz := coalesce(p_period_start, now());
begin
  return jsonb_build_object(
    'period_start', v_period_start,
    'period_end', public.billing_period_end(v_period_start, p_interval)
  );
end;
$$;

revoke all on function public.billing_period_bounds(text, timestamptz) from public;
revoke all on function public.billing_period_bounds(text, timestamptz) from anon, authenticated;
grant execute on function public.billing_period_bounds(text, timestamptz) to service_role;

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
  -- Legacy non-payment_attempt callers (for example old one-time Toss flows)
  -- use this calendar-month fallback. Toss BillingKey flows must activate via
  -- activate_payment_attempt(), using stored target_period_start/end.
  if p_interval = 'yearly' then
    v_ends := now() + interval '365 days';
  else
    v_ends := public.billing_period_end(now(), 'monthly');
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
revoke all on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb, boolean) from anon, authenticated;
grant execute on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb, boolean) to service_role;

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

revoke all on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb) from public;
revoke all on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb) from anon, authenticated;
grant execute on function public.activate_gym_pro(uuid, text, text, integer, text, text, text, jsonb) to service_role;

create or replace function public.activate_payment_attempt_core(
  p_attempt_id uuid,
  p_is_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attempt public.payment_attempts%rowtype;
  v_error_message text;
  v_gym_auto_renew boolean;
  v_gym_subscription_status text;
  v_next_subscription_status text;
  v_next_auto_renew boolean;
begin
  select * into v_attempt
  from public.payment_attempts
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'PAYMENT_ATTEMPT_NOT_FOUND';
  end if;

  if v_attempt.status = 'completed'
     and v_attempt.activation_status = 'succeeded' then
    return jsonb_build_object(
      'ok', true,
      'already_completed', true,
      'payment_attempt_id', v_attempt.id
    );
  end if;

  if v_attempt.status not in ('charge_succeeded', 'activation_pending', 'activation_failed', 'recovery_pending') then
    raise exception 'PAYMENT_ATTEMPT_NOT_RECOVERABLE:%', v_attempt.status;
  end if;

  if v_attempt.payment_key is null then
    raise exception 'PAYMENT_KEY_REQUIRED';
  end if;

  if v_attempt.target_period_start is null then
    raise exception 'TARGET_PERIOD_START_REQUIRED';
  end if;

  if v_attempt.target_period_end is null then
    raise exception 'TARGET_PERIOD_END_REQUIRED';
  end if;

  update public.payment_attempts
  set
    status = 'activation_pending',
    activation_status = 'pending',
    recovery_status = case when p_is_recovery then 'pending' else 'none' end,
    error_code = null,
    error_message = null
  where id = v_attempt.id;

  begin
    select auto_renew, subscription_status
    into v_gym_auto_renew, v_gym_subscription_status
    from public.gyms
    where id = v_attempt.gym_id
    for update;

    if not found then
      raise exception 'GYM_NOT_FOUND';
    end if;

    v_next_subscription_status := case
      when v_attempt.payment_type = 'auto_renewal'
           and v_gym_subscription_status = 'canceled' then 'canceled'
      else 'active'
    end;

    v_next_auto_renew := case
      when v_attempt.payment_type = 'auto_renewal'
           and (v_gym_subscription_status = 'canceled' or v_gym_auto_renew = false) then false
      else true
    end;

    perform set_config('app.allow_billing_update', '1', true);

    update public.gyms
    set
      plan_code = 'pro',
      member_limit = -1,
      subscription_status = v_next_subscription_status,
      current_period_end = v_attempt.target_period_end,
      billing_provider = v_attempt.provider,
      billing_customer_id = coalesce(v_attempt.customer_key, billing_customer_id),
      billing_subscription_id = coalesce(v_attempt.billing_key_ref, billing_subscription_id),
      auto_renew = v_next_auto_renew,
      updated_at = now()
    where id = v_attempt.gym_id;

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
      v_attempt.gym_id,
      'pro',
      'active',
      v_attempt.provider,
      coalesce(v_attempt.payment_key, v_attempt.billing_key_ref),
      v_attempt.amount_krw,
      v_attempt.target_period_start,
      v_attempt.target_period_end,
      jsonb_build_object(
        'activated_from_payment_attempt', v_attempt.id,
        'activation_mode', case when p_is_recovery then 'recovery' else 'normal' end,
        'payment_key', v_attempt.payment_key,
        'provider_response', coalesce(v_attempt.provider_response, '{}'::jsonb)
      )
    );

    update public.payment_attempts
    set
      status = 'completed',
      activation_status = 'succeeded',
      recovery_status = case when p_is_recovery then 'completed' else 'none' end,
      activated_at = coalesce(activated_at, now()),
      recovered_at = case when p_is_recovery then now() else recovered_at end,
      error_code = null,
      error_message = null
    where id = v_attempt.id;

    return jsonb_build_object(
      'ok', true,
      'already_completed', false,
      'payment_attempt_id', v_attempt.id,
      'target_period_start', v_attempt.target_period_start,
      'target_period_end', v_attempt.target_period_end
    );
  exception when others then
    v_error_message := left(sqlerrm, 500);

    update public.payment_attempts
    set
      status = 'activation_failed',
      activation_status = 'failed',
      recovery_status = case when p_is_recovery then 'failed' else recovery_status end,
      error_code = sqlstate,
      error_message = v_error_message
    where id = v_attempt.id;

    return jsonb_build_object(
      'ok', false,
      'payment_attempt_id', v_attempt.id,
      'error_code', sqlstate,
      'error_message', v_error_message
    );
  end;
end;
$$;

revoke all on function public.activate_payment_attempt_core(uuid, boolean) from public;
revoke all on function public.activate_payment_attempt_core(uuid, boolean) from anon, authenticated;
grant execute on function public.activate_payment_attempt_core(uuid, boolean) to service_role;

create or replace function public.activate_payment_attempt(p_attempt_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.activate_payment_attempt_core(p_attempt_id, false);
$$;

revoke all on function public.activate_payment_attempt(uuid) from public;
revoke all on function public.activate_payment_attempt(uuid) from anon, authenticated;
grant execute on function public.activate_payment_attempt(uuid) to service_role;

create or replace function public.recover_payment_attempt_activation(p_attempt_id uuid)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select public.activate_payment_attempt_core(p_attempt_id, true);
$$;

revoke all on function public.recover_payment_attempt_activation(uuid) from public;
revoke all on function public.recover_payment_attempt_activation(uuid) from anon, authenticated;
grant execute on function public.recover_payment_attempt_activation(uuid) to service_role;

create or replace function public.claim_due_toss_subscription_charges(
  p_now timestamptz default now(),
  p_limit integer default 50,
  p_amount_krw integer default 10000
)
returns table (
  payment_attempt_id uuid,
  gym_id uuid,
  user_id uuid,
  order_id text,
  customer_key text,
  billing_key_ref text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  amount_krw integer
)
language sql
security definer
set search_path = public
as $$
  with locked_due_gyms as (
    select
      g.id as gym_id,
      owner_profile.id as user_id,
      g.billing_customer_id as customer_key,
      g.billing_subscription_id as billing_key_ref,
      g.current_period_end as target_period_start
    from public.gyms g
    left join lateral (
      select p.id
      from public.profiles p
      where p.gym_id = g.id
      order by p.created_at asc
      limit 1
    ) owner_profile on true
    where g.billing_provider = 'toss'
      and g.auto_renew = true
      and g.subscription_status = 'active'
      and g.billing_customer_id is not null
      and g.billing_subscription_id is not null
      and g.current_period_end is not null
      and g.current_period_end <= p_now
    order by g.current_period_end asc, g.id asc
    limit greatest(least(coalesce(p_limit, 50), 100), 1)
    for update of g skip locked
  ),
  claim_rows as (
    select
      gen_random_uuid() as payment_attempt_id,
      gym_id,
      user_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      public.billing_period_end(target_period_start, 'monthly') as target_period_end,
      coalesce(p_amount_krw, 10000) as amount_krw
    from locked_due_gyms
  ),
  inserted_attempts as (
    insert into public.payment_attempts (
      id,
      gym_id,
      user_id,
      provider,
      payment_type,
      billing_interval,
      amount_krw,
      currency,
      order_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      target_period_end,
      status,
      activation_status,
      recovery_status,
      provider_response
    )
    select
      cr.payment_attempt_id,
      cr.gym_id,
      cr.user_id,
      'toss',
      'auto_renewal',
      'monthly',
      cr.amount_krw,
      'KRW',
      'toss_renew_' || replace(cr.payment_attempt_id::text, '-', ''),
      cr.customer_key,
      cr.billing_key_ref,
      cr.target_period_start,
      cr.target_period_end,
      'initiated',
      'not_started',
      'none',
      jsonb_build_object('mode', 'auto_renew_claim')
    from claim_rows cr
    on conflict do nothing
    returning
      id,
      gym_id,
      user_id,
      order_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      target_period_end,
      amount_krw
  )
  select
    ia.id as payment_attempt_id,
    ia.gym_id,
    ia.user_id,
    ia.order_id,
    ia.customer_key,
    ia.billing_key_ref,
    ia.target_period_start,
    ia.target_period_end,
    ia.amount_krw
  from inserted_attempts ia
  order by ia.target_period_start asc, ia.gym_id asc;
$$;

revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from public;
revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from anon, authenticated;
grant execute on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) to service_role;
