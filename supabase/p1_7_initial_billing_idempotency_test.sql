-- P1-7A initial billing idempotency rollback tests.
-- Safe to paste into SQL Editor after p1_7_initial_billing_idempotency.sql.
-- This test never calls Toss and rolls back all synthetic data.

begin;

create temp table p1_7_test_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_7_context (
  first_claim_gym_id uuid not null,
  initiated_gym_id uuid not null,
  auth_issued_gym_id uuid not null,
  charge_succeeded_gym_id uuid not null,
  activation_pending_gym_id uuid not null,
  activation_failed_gym_id uuid not null,
  completed_gym_id uuid not null,
  active_gym_id uuid not null,
  canceled_entitled_gym_id uuid not null,
  charge_failed_gym_id uuid not null,
  binding_gym_id uuid not null,
  customer_key text not null,
  period_start timestamptz not null,
  period_end timestamptz not null
) on commit drop;

insert into p1_7_context
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
  'p1_7_customer',
  '2026-01-31 00:00:00+00'::timestamptz,
  '2026-02-28 00:00:00+00'::timestamptz
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
select gym_id, name, 'P1-7 Owner', '010-0000-0000', plan_code, member_limit,
       subscription_status, current_period_end, billing_provider,
       billing_customer_id, billing_subscription_id, auto_renew
from p1_7_context ctx
cross join lateral (
  values
    (ctx.first_claim_gym_id, 'P1-7 First Claim Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.initiated_gym_id, 'P1-7 Initiated Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.auth_issued_gym_id, 'P1-7 Auth Issued Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.charge_succeeded_gym_id, 'P1-7 Charge Succeeded Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.activation_pending_gym_id, 'P1-7 Activation Pending Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.activation_failed_gym_id, 'P1-7 Activation Failed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.completed_gym_id, 'P1-7 Completed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.active_gym_id, 'P1-7 Active Gym', 'pro', -1, 'active', ctx.period_end, 'toss', ctx.customer_key, 'p1_7_billing_key_active', true),
    (ctx.canceled_entitled_gym_id, 'P1-7 Canceled Entitled Gym', 'pro', -1, 'canceled', now() + interval '30 days', 'toss', ctx.customer_key, 'p1_7_billing_key_canceled', false),
    (ctx.charge_failed_gym_id, 'P1-7 Charge Failed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.binding_gym_id, 'P1-7 Binding Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false)
) as g(gym_id, name, plan_code, member_limit, subscription_status, current_period_end, billing_provider, billing_customer_id, billing_subscription_id, auto_renew);

create temp table p1_7_gym_users on commit drop as
select gym_id, gen_random_uuid() as user_id
from p1_7_context ctx
cross join lateral (
  values
    (ctx.first_claim_gym_id),
    (ctx.initiated_gym_id),
    (ctx.auth_issued_gym_id),
    (ctx.charge_succeeded_gym_id),
    (ctx.activation_pending_gym_id),
    (ctx.activation_failed_gym_id),
    (ctx.completed_gym_id),
    (ctx.active_gym_id),
    (ctx.canceled_entitled_gym_id),
    (ctx.charge_failed_gym_id),
    (ctx.binding_gym_id)
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
  'p1_7_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_7_gym_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-7 Test User'
from p1_7_gym_users
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

create function pg_temp.p1_7_user_for(p_gym_id uuid)
returns uuid
language sql
stable
as $$
  select user_id
  from p1_7_gym_users
  where gym_id = p_gym_id
$$;

insert into public.payment_attempts (
  id,
  gym_id,
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
  'toss',
  'initial_billing',
  'monthly',
  10000,
  'KRW',
  order_id,
  ctx.customer_key,
  billing_key_ref,
  payment_key,
  ctx.period_start,
  ctx.period_end,
  status,
  activation_status,
  recovery_status,
  jsonb_build_object('mode', 'p1_7_test_seed')
from p1_7_context ctx
cross join lateral (
  values
    (ctx.initiated_gym_id, 'p1_7_initiated_order', null::text, null::text, 'initiated', 'not_started', 'none'),
    (ctx.auth_issued_gym_id, 'p1_7_auth_issued_order', 'p1_7_billing_key_auth', null::text, 'auth_issued', 'not_started', 'none'),
    (ctx.charge_succeeded_gym_id, 'p1_7_charge_succeeded_order', 'p1_7_billing_key_charge', 'p1_7_payment_charge', 'charge_succeeded', 'pending', 'none'),
    (ctx.activation_pending_gym_id, 'p1_7_activation_pending_order', 'p1_7_billing_key_pending', 'p1_7_payment_pending', 'activation_pending', 'pending', 'none'),
    (ctx.activation_failed_gym_id, 'p1_7_activation_failed_order', 'p1_7_billing_key_failed_activation', 'p1_7_payment_failed_activation', 'activation_failed', 'failed', 'pending'),
    (ctx.completed_gym_id, 'p1_7_completed_order', 'p1_7_billing_key_completed', 'p1_7_payment_completed', 'completed', 'succeeded', 'none'),
    (ctx.charge_failed_gym_id, 'p1_7_charge_failed_order', null::text, null::text, 'charge_failed', 'not_started', 'none')
) as pa(gym_id, order_id, billing_key_ref, payment_key, status, activation_status, recovery_status);

create temp table p1_7_first_claim on commit drop as
select public.claim_initial_billing_attempt(
  ctx.first_claim_gym_id,
  pg_temp.p1_7_user_for(ctx.first_claim_gym_id),
  ctx.customer_key,
  10000
) as result
from p1_7_context ctx;

create temp table p1_7_second_claim on commit drop as
select public.claim_initial_billing_attempt(
  ctx.first_claim_gym_id,
  pg_temp.p1_7_user_for(ctx.first_claim_gym_id),
  ctx.customer_key,
  10000
) as result
from p1_7_context ctx;

insert into p1_7_test_results
select
  'TEST 1: first claim can charge',
  case when result->>'can_charge' = 'true'
         and result->>'action' = 'charge'
       then 'PASS' else 'FAIL' end,
  result::text
from p1_7_first_claim;

insert into p1_7_test_results
select
  'TEST 2: second claim cannot charge and creates no new attempt',
  case when result->>'can_charge' = 'false'
         and result->>'action' = 'processing'
         and (
           select count(*)
           from public.payment_attempts pa
           join p1_7_context ctx on ctx.first_claim_gym_id = pa.gym_id
           where pa.payment_type = 'initial_billing'
         ) = 1
       then 'PASS' else 'FAIL' end,
  result::text
from p1_7_second_claim;

insert into p1_7_test_results
select
  'TEST 3: initiated returns processing',
  case when r.result->>'action' = 'processing'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.initiated_gym_id, pg_temp.p1_7_user_for(ctx.initiated_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 4: auth_issued returns processing',
  case when r.result->>'action' = 'processing'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.auth_issued_gym_id, pg_temp.p1_7_user_for(ctx.auth_issued_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 5: charge_succeeded with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.charge_succeeded_gym_id, pg_temp.p1_7_user_for(ctx.charge_succeeded_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 6: activation_pending with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.activation_pending_gym_id, pg_temp.p1_7_user_for(ctx.activation_pending_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 7: activation_failed with payment_key returns needs_recovery',
  case when r.result->>'action' = 'needs_recovery'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.activation_failed_gym_id, pg_temp.p1_7_user_for(ctx.activation_failed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 8: historical completed succeeded does not block new claim',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.completed_gym_id, pg_temp.p1_7_user_for(ctx.completed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 9: active paid Pro returns already_completed',
  case when r.result->>'action' = 'already_completed'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.active_gym_id, pg_temp.p1_7_user_for(ctx.active_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 10: canceled paid entitlement returns already_completed',
  case when r.result->>'action' = 'already_completed'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.canceled_entitled_gym_id, pg_temp.p1_7_user_for(ctx.canceled_entitled_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 11: charge_failed returns do_not_charge',
  case when r.result->>'action' = 'do_not_charge'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.charge_failed_gym_id, pg_temp.p1_7_user_for(ctx.charge_failed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7_test_results
select
  'TEST 12: stable order id derives from attempt id',
  case when fc.result->>'order_id' = 'toss_bill_' || replace(fc.result->>'payment_attempt_id', '-', '')
         and sc.result->>'order_id' = fc.result->>'order_id'
       then 'PASS' else 'FAIL' end,
  'first=' || fc.result::text || ', second=' || sc.result::text
from p1_7_first_claim fc
cross join p1_7_second_claim sc;

do $$
declare
  v_result jsonb;
begin
  select public.claim_initial_billing_attempt(
    binding_gym_id,
    null,
    customer_key,
    10000
  )
  into v_result
  from p1_7_context;

  insert into p1_7_test_results
  values ('TEST 13: null user is rejected', 'FAIL', v_result::text);
exception when others then
  insert into p1_7_test_results
  values (
    'TEST 13: null user is rejected',
    case when sqlerrm like '%AUTH_REQUIRED%' then 'PASS' else 'FAIL' end,
    sqlerrm
  );
end; $$;

do $$
declare
  v_result jsonb;
begin
  select public.claim_initial_billing_attempt(
    binding_gym_id,
    pg_temp.p1_7_user_for(first_claim_gym_id),
    customer_key,
    10000
  )
  into v_result
  from p1_7_context;

  insert into p1_7_test_results
  values ('TEST 14: mismatched user/gym binding is rejected', 'FAIL', v_result::text);
exception when others then
  insert into p1_7_test_results
  values (
    'TEST 14: mismatched user/gym binding is rejected',
    case when sqlerrm like '%USER_GYM_MISMATCH%' then 'PASS' else 'FAIL' end,
    sqlerrm
  );
end; $$;

insert into p1_7_test_results
values (
  'TEST 15: concurrency coverage note',
  'PASS',
  'True concurrent transaction behavior requires two sessions; this rollback file verifies sequential idempotency and state policy only.'
);

select *
from p1_7_test_results
order by test_name;

rollback;
