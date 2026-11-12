-- =============================================================================
-- Rollback for complimentary Pro.
--
-- Re-applying this file is safe. It restores the previous billing functions,
-- drops the one-time apply and rollback functions, and drops the marker
-- columns. It does not delete gyms, members, or payment attempts.
-- Run it only to undo supabase/p1_19_complimentary_pro.sql.
-- Clearing one gym without removing the feature is
-- public.rollback_complimentary_pro(gym_id), before this file is applied.
-- Dropping the apply function does not read or modify stored billing keys.
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
           and p_gym.subscription_status = 'active'
           and p_gym.current_period_end is not null
           and p_gym.current_period_end > now() then true
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

create or replace function public.activate_payment_attempt_core(
  p_attempt_id uuid,
  p_is_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = private, public
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

  if v_attempt.provider = 'toss'
     and v_attempt.billing_key_ref is not null
     and length(btrim(v_attempt.billing_key_ref)) > 0 then
    insert into private.billing_credentials (
      gym_id,
      provider,
      billing_key
    )
    values (
      v_attempt.gym_id,
      'toss',
      btrim(v_attempt.billing_key_ref)
    )
    on conflict (gym_id, provider) do update
    set
      billing_key = excluded.billing_key,
      updated_at = now()
    where private.billing_credentials.billing_key is distinct from excluded.billing_key;

    update public.payment_attempts
    set billing_key_ref = null
    where id = v_attempt.id;
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
      current_period_end = case
        when current_period_end is null
          or current_period_end < v_attempt.target_period_end then v_attempt.target_period_end
        else current_period_end
      end,
      billing_provider = v_attempt.provider,
      billing_customer_id = coalesce(v_attempt.customer_key, billing_customer_id),
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
      v_attempt.payment_key,
      v_attempt.amount_krw,
      v_attempt.target_period_start,
      v_attempt.target_period_end,
      private.redact_sensitive_payload(jsonb_build_object(
        'activated_from_payment_attempt', v_attempt.id,
        'activation_mode', case when p_is_recovery then 'recovery' else 'normal' end,
        'payment_key', v_attempt.payment_key,
        'provider_response', coalesce(v_attempt.provider_response, '{}'::jsonb)
      ))
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
set search_path = private, public
as $$
  with locked_due_gyms as (
    select
      g.id as gym_id,
      owner_profile.id as user_id,
      g.billing_customer_id as customer_key,
      private.resolve_toss_billing_credential(g.id) as billing_key_ref,
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
      and private.resolve_toss_billing_credential(g.id) is not null
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
      null::text,
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
    cr.billing_key_ref,
    ia.target_period_start,
    ia.target_period_end,
    ia.amount_krw
  from inserted_attempts ia
  join claim_rows cr on cr.payment_attempt_id = ia.id
  order by ia.target_period_start asc, ia.gym_id asc;
$$;

revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from public;
revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from anon, authenticated;
grant execute on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) to service_role;

create or replace function public.claim_initial_billing_attempt(
  p_gym_id uuid,
  p_user_id uuid default null,
  p_customer_key text default null,
  p_amount_krw integer default 10000
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
  v_attempt public.payment_attempts%rowtype;
  v_auto_renewal_attempt public.payment_attempts%rowtype;
  v_attempt_id uuid;
  v_order_id text;
  v_period jsonb;
  v_period_start timestamptz;
  v_period_end timestamptz;
  v_amount_krw integer := coalesce(p_amount_krw, 10000);
begin
  if p_gym_id is null then
    raise exception 'GYM_ID_REQUIRED';
  end if;

  if p_customer_key is null or length(trim(p_customer_key)) = 0 then
    raise exception 'CUSTOMER_KEY_REQUIRED';
  end if;

  if v_amount_krw < 0 then
    raise exception 'AMOUNT_INVALID';
  end if;

  if p_user_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  if not exists (
    select 1
    from public.profiles p
    where p.id = p_user_id
      and p.gym_id = p_gym_id
  ) then
    raise exception 'USER_GYM_MISMATCH';
  end if;

  select *
  into v_gym
  from public.gyms
  where id = p_gym_id
  for update;

  if not found then
    raise exception 'GYM_NOT_FOUND';
  end if;

  -- A paid Pro period is complete only while current_period_end is still
  -- in the future. active + auto_renew is not an entitlement by itself:
  -- an expired period must reach the auto-renewal and recovery guards below.
  if v_gym.plan_code = 'pro'
     and v_gym.current_period_end is not null
     and v_gym.current_period_end > now() then
    return jsonb_build_object(
      'ok', true,
      'action', 'already_completed',
      'can_charge', false,
      'already_completed', true,
      'gym_id', v_gym.id,
      'gym_name', v_gym.name,
      'plan_code', v_gym.plan_code,
      'subscription_status', v_gym.subscription_status,
      'current_period_end', v_gym.current_period_end
    );
  end if;

  select *
  into v_auto_renewal_attempt
  from public.payment_attempts pa
  where pa.gym_id = p_gym_id
    and pa.provider = 'toss'
    and pa.payment_type = 'auto_renewal'
    and pa.status in (
      'initiated',
      'charge_failed',
      'charge_succeeded',
      'activation_pending',
      'activation_failed',
      'recovery_pending'
    )
  order by pa.created_at desc, pa.id desc
  limit 1
  for update;

  if found then
    if v_auto_renewal_attempt.status in ('charge_succeeded', 'activation_pending', 'activation_failed', 'recovery_pending')
       and v_auto_renewal_attempt.payment_key is not null then
      return jsonb_build_object(
        'ok', true,
        'action', 'needs_recovery',
        'can_charge', false,
        'payment_attempt_id', v_auto_renewal_attempt.id,
        'order_id', v_auto_renewal_attempt.order_id,
        'payment_type', v_auto_renewal_attempt.payment_type,
        'status', v_auto_renewal_attempt.status,
        'activation_status', v_auto_renewal_attempt.activation_status,
        'recovery_status', v_auto_renewal_attempt.recovery_status,
        'target_period_start', v_auto_renewal_attempt.target_period_start,
        'target_period_end', v_auto_renewal_attempt.target_period_end
      );
    end if;

    return jsonb_build_object(
      'ok', true,
      'action', 'do_not_charge',
      'can_charge', false,
      'payment_attempt_id', v_auto_renewal_attempt.id,
      'order_id', v_auto_renewal_attempt.order_id,
      'payment_type', v_auto_renewal_attempt.payment_type,
      'status', v_auto_renewal_attempt.status,
      'activation_status', v_auto_renewal_attempt.activation_status,
      'recovery_status', v_auto_renewal_attempt.recovery_status,
      'target_period_start', v_auto_renewal_attempt.target_period_start,
      'target_period_end', v_auto_renewal_attempt.target_period_end
    );
  end if;

  select *
  into v_attempt
  from public.payment_attempts pa
  where pa.gym_id = p_gym_id
    and pa.provider = 'toss'
    and pa.payment_type = 'initial_billing'
    and (
      pa.recovery_status = 'failed'
      or pa.status <> 'completed'
      or pa.activation_status <> 'succeeded'
    )
  order by pa.created_at desc, pa.id desc
  limit 1
  for update;

  if found then
    if v_attempt.recovery_status = 'failed' then
      return jsonb_build_object(
        'ok', true,
        'action', 'do_not_charge',
        'can_charge', false,
        'payment_attempt_id', v_attempt.id,
        'order_id', v_attempt.order_id,
        'status', v_attempt.status,
        'activation_status', v_attempt.activation_status,
        'recovery_status', v_attempt.recovery_status,
        'target_period_start', v_attempt.target_period_start,
        'target_period_end', v_attempt.target_period_end
      );
    end if;

    if v_attempt.status = 'completed'
       and v_attempt.activation_status = 'succeeded' then
      return jsonb_build_object(
        'ok', true,
        'action', 'already_completed',
        'can_charge', false,
        'already_completed', true,
        'payment_attempt_id', v_attempt.id,
        'order_id', v_attempt.order_id,
        'status', v_attempt.status,
        'activation_status', v_attempt.activation_status,
        'recovery_status', v_attempt.recovery_status,
        'target_period_start', v_attempt.target_period_start,
        'target_period_end', v_attempt.target_period_end
      );
    end if;

    if v_attempt.status in ('charge_succeeded', 'activation_pending', 'activation_failed', 'recovery_pending')
       and v_attempt.payment_key is not null then
      return jsonb_build_object(
        'ok', true,
        'action', 'needs_recovery',
        'can_charge', false,
        'payment_attempt_id', v_attempt.id,
        'order_id', v_attempt.order_id,
        'status', v_attempt.status,
        'activation_status', v_attempt.activation_status,
        'recovery_status', v_attempt.recovery_status,
        'target_period_start', v_attempt.target_period_start,
        'target_period_end', v_attempt.target_period_end
      );
    end if;

    if v_attempt.status = 'charge_failed' then
      return jsonb_build_object(
        'ok', true,
        'action', 'do_not_charge',
        'can_charge', false,
        'payment_attempt_id', v_attempt.id,
        'order_id', v_attempt.order_id,
        'status', v_attempt.status,
        'activation_status', v_attempt.activation_status,
        'recovery_status', v_attempt.recovery_status,
        'target_period_start', v_attempt.target_period_start,
        'target_period_end', v_attempt.target_period_end
      );
    end if;

    return jsonb_build_object(
      'ok', true,
      'action', 'processing',
      'can_charge', false,
      'payment_attempt_id', v_attempt.id,
      'order_id', v_attempt.order_id,
      'status', v_attempt.status,
      'activation_status', v_attempt.activation_status,
      'recovery_status', v_attempt.recovery_status,
      'target_period_start', v_attempt.target_period_start,
      'target_period_end', v_attempt.target_period_end
    );
  end if;

  v_attempt_id := gen_random_uuid();
  v_order_id := 'toss_bill_' || replace(v_attempt_id::text, '-', '');
  v_period := public.billing_period_bounds('monthly');
  v_period_start := (v_period->>'period_start')::timestamptz;
  v_period_end := (v_period->>'period_end')::timestamptz;

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
    target_period_start,
    target_period_end,
    status,
    activation_status,
    recovery_status,
    provider_response
  )
  values (
    v_attempt_id,
    p_gym_id,
    p_user_id,
    'toss',
    'initial_billing',
    'monthly',
    v_amount_krw,
    'KRW',
    v_order_id,
    p_customer_key,
    v_period_start,
    v_period_end,
    'initiated',
    'not_started',
    'none',
    jsonb_build_object('mode', 'initial_billing_claim')
  );

  return jsonb_build_object(
    'ok', true,
    'action', 'charge',
    'can_charge', true,
    'payment_attempt_id', v_attempt_id,
    'order_id', v_order_id,
    'target_period_start', v_period_start,
    'target_period_end', v_period_end,
    'amount_krw', v_amount_krw,
    'gym_id', v_gym.id,
    'gym_name', v_gym.name
  );
end;
$$;

revoke all on function public.claim_initial_billing_attempt(uuid, uuid, text, integer) from public;
revoke all on function public.claim_initial_billing_attempt(uuid, uuid, text, integer) from anon, authenticated;
grant execute on function public.claim_initial_billing_attempt(uuid, uuid, text, integer) to service_role;

create or replace function public.cancel_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = private, public
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
    null,
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
revoke all on function public.cancel_gym_subscription() from anon;
grant execute on function public.cancel_gym_subscription() to authenticated;

create or replace function public.resume_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = private, public
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

  if v_gym.billing_customer_id is null
     or not private.gym_has_billing_credential(v_gym.id) then
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
    null,
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

revoke all on function public.resume_gym_subscription() from public;
revoke all on function public.resume_gym_subscription() from anon;
grant execute on function public.resume_gym_subscription() to authenticated;

create or replace function public.get_billing_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = private, public
as $$
declare
  v_gym public.gyms%rowtype;
  v_count integer;
  v_limit integer;
  v_pro boolean;
  v_has_credential boolean;
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
  v_has_credential := private.gym_has_billing_credential(v_gym.id);

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
      and v_gym.billing_customer_id is not null
      and v_has_credential
    ),
    'auto_renew', coalesce(v_gym.auto_renew, false),
    'billing_provider', v_gym.billing_provider
  );
end;
$$;

revoke all on function public.get_billing_summary() from public;
revoke all on function public.get_billing_summary() from anon;
grant execute on function public.get_billing_summary() to authenticated;


drop function if exists public.apply_complimentary_pro(uuid, text);
drop function if exists public.rollback_complimentary_pro(uuid);

alter table public.gyms
  drop column if exists complimentary_pro_reason,
  drop column if exists complimentary_pro_at,
  drop column if exists complimentary_pro;
