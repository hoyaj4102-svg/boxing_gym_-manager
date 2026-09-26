-- =============================================================================
-- Durable payment attempt tracking + activation recovery
-- Run after monthly_billing.sql
-- =============================================================================

create table if not exists public.payment_attempts (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  user_id uuid references auth.users (id) on delete set null,
  provider text not null check (provider in ('toss', 'stripe')),
  payment_type text not null check (payment_type in ('initial_billing', 'auto_renewal', 'legacy_checkout')),
  billing_interval text not null default 'monthly' check (billing_interval in ('monthly', 'yearly')),
  amount_krw integer not null check (amount_krw >= 0),
  currency text not null default 'KRW',
  order_id text not null unique,
  payment_key text unique,
  customer_key text,
  billing_key_ref text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  status text not null default 'initiated'
    check (status in (
      'initiated',
      'auth_issued',
      'charge_succeeded',
      'activation_pending',
      'completed',
      'charge_failed',
      'activation_failed',
      'recovery_pending'
    )),
  activation_status text not null default 'not_started'
    check (activation_status in ('not_started', 'pending', 'succeeded', 'failed')),
  recovery_status text not null default 'none'
    check (recovery_status in ('none', 'pending', 'completed', 'failed')),
  error_code text,
  error_message text,
  provider_response jsonb not null default '{}'::jsonb,
  activated_at timestamptz,
  recovered_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists payment_attempts_gym_created_idx
  on public.payment_attempts (gym_id, created_at desc);

create index if not exists payment_attempts_status_idx
  on public.payment_attempts (status);

create index if not exists payment_attempts_recovery_idx
  on public.payment_attempts (recovery_status, status)
  where status in ('activation_failed', 'recovery_pending');

drop trigger if exists payment_attempts_set_updated_at on public.payment_attempts;
create trigger payment_attempts_set_updated_at
before update on public.payment_attempts
for each row
execute function public.set_updated_at();

alter table public.payment_attempts enable row level security;

drop policy if exists "Gym can view own payment attempts" on public.payment_attempts;
create policy "Gym can view own payment attempts"
on public.payment_attempts
for select
to authenticated
using (gym_id = public.current_gym_id());

-- Writes and recovery are performed by service role Edge Functions / operators.

create or replace function public.recover_payment_attempt_activation(p_attempt_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_attempt public.payment_attempts%rowtype;
  v_error_message text;
  v_period_end timestamptz;
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

  if v_attempt.target_period_end is null then
    raise exception 'TARGET_PERIOD_END_REQUIRED';
  end if;

  v_period_end := v_attempt.target_period_end;

  update public.payment_attempts
  set
    status = 'recovery_pending',
    activation_status = 'pending',
    recovery_status = 'pending',
    error_code = null,
    error_message = null
  where id = v_attempt.id;

  begin
    perform set_config('app.allow_billing_update', '1', true);

    update public.gyms
    set
      plan_code = 'pro',
      member_limit = -1,
      subscription_status = 'active',
      current_period_end = v_period_end,
      billing_provider = v_attempt.provider,
      billing_customer_id = coalesce(v_attempt.customer_key, billing_customer_id),
      billing_subscription_id = coalesce(v_attempt.billing_key_ref, billing_subscription_id),
      auto_renew = true,
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
      coalesce(v_attempt.target_period_start, v_attempt.created_at, now()),
      v_period_end,
      jsonb_build_object(
        'recovered_from_payment_attempt', v_attempt.id,
        'payment_key', v_attempt.payment_key,
        'provider_response', coalesce(v_attempt.provider_response, '{}'::jsonb)
      )
    );

    update public.payment_attempts
    set
      status = 'completed',
      activation_status = 'succeeded',
      recovery_status = 'completed',
      activated_at = coalesce(activated_at, now()),
      recovered_at = now(),
      error_code = null,
      error_message = null
    where id = v_attempt.id;

    return jsonb_build_object(
      'ok', true,
      'already_completed', false,
      'payment_attempt_id', v_attempt.id
    );
  exception when others then
    v_error_message := left(sqlerrm, 500);

    update public.payment_attempts
    set
      status = 'activation_failed',
      activation_status = 'failed',
      recovery_status = 'failed',
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

revoke all on function public.recover_payment_attempt_activation(uuid) from public;
grant execute on function public.recover_payment_attempt_activation(uuid) to service_role;
