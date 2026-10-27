-- P1-9C initial billing vs auto-renewal duplicate-charge guard rollback tests.
-- Safe to paste into SQL Editor after applying:
--   1. payment_attempts.sql
--   2. p0_2_payment_claim.sql
--   3. p1_7_initial_billing_idempotency.sql
-- This test never calls Toss and rolls back all synthetic data.

begin;

create temp table p1_9c_test_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_9c_context (
  active_future_auto_false_gym_id uuid not null,
  canceled_future_gym_id uuid not null,
  active_expired_auto_true_gym_id uuid not null,
  expired_auto_false_clear_gym_id uuid not null,
  auto_initiated_gym_id uuid not null,
  auto_charge_failed_gym_id uuid not null,
  auto_charge_succeeded_gym_id uuid not null,
  auto_activation_pending_gym_id uuid not null,
  auto_activation_failed_gym_id uuid not null,
  auto_recovery_pending_gym_id uuid not null,
  auto_completed_gym_id uuid not null,
  customer_key text not null,
  period_start timestamptz not null,
  expired_period_end timestamptz not null,
  future_period_end timestamptz not null
) on commit drop;

insert into p1_9c_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  'p1_9c_customer',
  now() - interval '30 days',
  now() - interval '1 day',
  now() + interval '30 days'
);

insert into public.gyms (
  id,
  name,
  owner_name,
  phone,
  plan_code,
  member_limit,
  subscription_status,
  current_period_end,
  billing_provider,
  billing_customer_id,
  billing_subscription_id,
  auto_renew
)
select
  gym_id,
  name,
  'P1-9C Owner',
  '010-0000-0000',
  'pro',
  -1,
  subscription_status,
  current_period_end,
  'toss',
  ctx.customer_key,
  billing_key_ref,
  auto_renew
from p1_9c_context ctx
cross join lateral (
  values
    (ctx.active_future_auto_false_gym_id, 'P1-9C Active Future Auto False Gym', 'active', ctx.future_period_end, 'p1_9c_billing_key_active_false', false),
    (ctx.canceled_future_gym_id, 'P1-9C Canceled Future Gym', 'canceled', ctx.future_period_end, 'p1_9c_billing_key_canceled', false),
    (ctx.active_expired_auto_true_gym_id, 'P1-9C Active Expired Auto True Gym', 'active', ctx.expired_period_end, 'p1_9c_billing_key_auto_true', true),
    (ctx.expired_auto_false_clear_gym_id, 'P1-9C Expired Auto False Clear Gym', 'expired', ctx.expired_period_end, null::text, false),
    (ctx.auto_initiated_gym_id, 'P1-9C Auto Initiated Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_initiated', false),
    (ctx.auto_charge_failed_gym_id, 'P1-9C Auto Charge Failed Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_charge_failed', false),
    (ctx.auto_charge_succeeded_gym_id, 'P1-9C Auto Charge Succeeded Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_charge_succeeded', false),
    (ctx.auto_activation_pending_gym_id, 'P1-9C Auto Activation Pending Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_activation_pending', false),
    (ctx.auto_activation_failed_gym_id, 'P1-9C Auto Activation Failed Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_activation_failed', false),
    (ctx.auto_recovery_pending_gym_id, 'P1-9C Auto Recovery Pending Gym', 'past_due', ctx.expired_period_end, 'p1_9c_billing_key_recovery_pending', false),
    (ctx.auto_completed_gym_id, 'P1-9C Auto Completed Historical Gym', 'expired', ctx.expired_period_end, 'p1_9c_billing_key_completed', false)
) as g(gym_id, name, subscription_status, current_period_end, billing_key_ref, auto_renew);

create temp table p1_9c_gym_users on commit drop as
select gym_id, gen_random_uuid() as user_id
from p1_9c_context ctx
cross join lateral (
  values
    (ctx.active_future_auto_false_gym_id),
    (ctx.canceled_future_gym_id),
    (ctx.active_expired_auto_true_gym_id),
    (ctx.expired_auto_false_clear_gym_id),
    (ctx.auto_initiated_gym_id),
    (ctx.auto_charge_failed_gym_id),
    (ctx.auto_charge_succeeded_gym_id),
    (ctx.auto_activation_pending_gym_id),
    (ctx.auto_activation_failed_gym_id),
    (ctx.auto_recovery_pending_gym_id),
    (ctx.auto_completed_gym_id)
) as g(gym_id);

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data
)
select
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  'p1_9c_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_9c_gym_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-9C Test User'
from p1_9c_gym_users
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

create function pg_temp.p1_9c_user_for(p_gym_id uuid)
returns uuid
language sql
stable
as $$
  select user_id
  from p1_9c_gym_users
  where gym_id = p_gym_id
$$;

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
  payment_key,
  target_period_start,
  target_period_end,
  status,
  activation_status,
  recovery_status,
  provider_response
)
select
  gen_random_uuid(),
  gym_id,
  pg_temp.p1_9c_user_for(gym_id),
  'toss',
  'auto_renewal',
  'monthly',
  10000,
  'KRW',
  order_id,
  ctx.customer_key,
  billing_key_ref,
  payment_key,
  ctx.period_start,
  ctx.expired_period_end,
  attempt_status,
  activation_status,
  recovery_status,
  '{}'::jsonb
from p1_9c_context ctx
cross join lateral (
  values
    (ctx.auto_initiated_gym_id, 'p1_9c_auto_initiated_order', 'p1_9c_billing_key_initiated', null::text, 'initiated', 'not_started', 'none'),
    (ctx.auto_charge_failed_gym_id, 'p1_9c_auto_charge_failed_order', 'p1_9c_billing_key_charge_failed', null::text, 'charge_failed', 'not_started', 'none'),
    (ctx.auto_charge_succeeded_gym_id, 'p1_9c_auto_charge_succeeded_order', 'p1_9c_billing_key_charge_succeeded', 'p1_9c_payment_charge_succeeded', 'charge_succeeded', 'pending', 'none'),
    (ctx.auto_activation_pending_gym_id, 'p1_9c_auto_activation_pending_order', 'p1_9c_billing_key_activation_pending', 'p1_9c_payment_activation_pending', 'activation_pending', 'pending', 'none'),
    (ctx.auto_activation_failed_gym_id, 'p1_9c_auto_activation_failed_order', 'p1_9c_billing_key_activation_failed', 'p1_9c_payment_activation_failed', 'activation_failed', 'failed', 'pending'),
    (ctx.auto_recovery_pending_gym_id, 'p1_9c_auto_recovery_pending_order', 'p1_9c_billing_key_recovery_pending', 'p1_9c_payment_recovery_pending', 'recovery_pending', 'pending', 'pending'),
    (ctx.auto_completed_gym_id, 'p1_9c_auto_completed_order', 'p1_9c_billing_key_completed', 'p1_9c_payment_completed', 'completed', 'succeeded', 'none')
) as pa(gym_id, order_id, billing_key_ref, payment_key, attempt_status, activation_status, recovery_status);

insert into p1_9c_test_results
select
  'TEST 1: active Pro with remaining period blocks even when auto_renew is false',
  case when r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.active_future_auto_false_gym_id, pg_temp.p1_9c_user_for(ctx.active_future_auto_false_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 2: canceled Pro with remaining period blocks',
  case when r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.canceled_future_gym_id, pg_temp.p1_9c_user_for(ctx.canceled_future_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 3: expired active auto_renew Pro blocks initial billing',
  case when r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.active_expired_auto_true_gym_id, pg_temp.p1_9c_user_for(ctx.active_expired_auto_true_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 4: expired auto_renew false with no unresolved auto attempt can charge',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.expired_auto_false_clear_gym_id, pg_temp.p1_9c_user_for(ctx.expired_auto_false_clear_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 5: auto_renewal initiated blocks initial billing',
  case when r.result->>'action' = 'do_not_charge'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_initiated_gym_id, pg_temp.p1_9c_user_for(ctx.auto_initiated_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 6: auto_renewal charge_failed blocks initial billing',
  case when r.result->>'action' = 'do_not_charge'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_charge_failed_gym_id, pg_temp.p1_9c_user_for(ctx.auto_charge_failed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 7: auto_renewal charge_succeeded with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_charge_succeeded_gym_id, pg_temp.p1_9c_user_for(ctx.auto_charge_succeeded_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 8: auto_renewal activation_pending with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_activation_pending_gym_id, pg_temp.p1_9c_user_for(ctx.auto_activation_pending_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 9: auto_renewal activation_failed with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_activation_failed_gym_id, pg_temp.p1_9c_user_for(ctx.auto_activation_failed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 10: auto_renewal recovery_pending with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'payment_type' = 'auto_renewal'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_recovery_pending_gym_id, pg_temp.p1_9c_user_for(ctx.auto_recovery_pending_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_9c_test_results
select
  'TEST 11: completed auto_renewal attempt does not block expired auto_renew false gym',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_9c_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auto_completed_gym_id, pg_temp.p1_9c_user_for(ctx.auto_completed_gym_id), ctx.customer_key, 10000) r(result);

select *
from p1_9c_test_results
order by test_name;

rollback;
