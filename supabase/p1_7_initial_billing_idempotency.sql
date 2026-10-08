-- =============================================================================
-- P1-7A Initial billing idempotency claim
-- Prevent duplicate first charges by allowing only one request per gym to claim
-- the right to call Toss for an initial_billing attempt.
-- =============================================================================

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

  if v_gym.plan_code = 'pro'
     and v_gym.billing_provider = 'toss'
     and v_gym.billing_customer_id = p_customer_key
     and v_gym.billing_subscription_id is not null
     and (
       (v_gym.subscription_status = 'active' and v_gym.auto_renew = true)
       or (
         v_gym.subscription_status = 'canceled'
         and v_gym.current_period_end is not null
         and v_gym.current_period_end > now()
       )
     ) then
    return jsonb_build_object(
      'ok', true,
      'action', 'already_completed',
      'can_charge', false,
      'already_completed', true,
      'gym_id', v_gym.id,
      'gym_name', v_gym.name
    );
  end if;

  select *
  into v_attempt
  from public.payment_attempts pa
  where pa.gym_id = p_gym_id
    and pa.provider = 'toss'
    and pa.payment_type = 'initial_billing'
    and not (
      pa.payment_key is null
      and pa.recovery_status = 'completed'
      and pa.provider_response #>> '{initial_reconciliation,result}' = 'confirmed_no_payment'
    )
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
