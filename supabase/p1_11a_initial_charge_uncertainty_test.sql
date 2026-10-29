-- P1-11A initial billing uncertain charge rollback tests.
-- Safe to paste into SQL Editor after applying:
--   1. payment_attempts.sql
--   2. p1_7_initial_billing_idempotency.sql
--   3. p1_7b_initial_billing_reconciliation.sql
--
-- This test never calls Toss or Edge Functions. It rolls back all synthetic data.

begin;

set local timezone to 'UTC';

create temp table p1_11a_test_results (
  test_name text not null,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_11a_context (
  uncertain_gym_id uuid not null,
  uncertain_user_id uuid not null,
  uncertain_attempt_id uuid not null,
  fallback_gym_id uuid not null,
  fallback_user_id uuid not null,
  fallback_attempt_id uuid not null,
  customer_key text not null,
  billing_key_ref text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  stale_created_at timestamptz not null
) on commit drop;

insert into p1_11a_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  'p1_11a_customer',
  'p1_11a_billing_key',
  now(),
  now() + interval '1 month',
  now() - interval '30 minutes'
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
select gym_id, gym_name, 'P1-11A Owner', '010-0000-0000', 'free', 20,
       'expired', null::timestamptz, null::text, null::text, null::text, false
from p1_11a_context ctx
cross join lateral (
  values
    (ctx.uncertain_gym_id, 'P1-11A Uncertain Charge Gym'),
    (ctx.fallback_gym_id, 'P1-11A Fallback Auth Issued Gym')
) as g(gym_id, gym_name);

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
select user_id,
       '00000000-0000-0000-0000-000000000000'::uuid,
       'authenticated',
       'authenticated',
       email,
       '',
       now(),
       now(),
       now(),
       '{"provider":"email","providers":["email"]}'::jsonb,
       '{}'::jsonb
from p1_11a_context ctx
cross join lateral (
  values
    (ctx.uncertain_user_id, 'p1_11a_uncertain@example.invalid'),
    (ctx.fallback_user_id, 'p1_11a_fallback@example.invalid')
) as users_to_insert(user_id, email);

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-11A Test User'
from p1_11a_context ctx
cross join lateral (
  values
    (ctx.uncertain_user_id, ctx.uncertain_gym_id),
    (ctx.fallback_user_id, ctx.fallback_gym_id)
) as profiles_to_insert(user_id, gym_id);

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
  error_code,
  error_message,
  provider_response,
  created_at,
  updated_at
)
select attempt_id,
       gym_id,
       user_id,
       'toss',
       'initial_billing',
       'monthly',
       10000,
       'KRW',
       order_id,
       ctx.customer_key,
       ctx.billing_key_ref,
       null::text,
       ctx.period_start,
       ctx.period_end,
       attempt_status,
       'not_started',
       recovery_status,
       error_code,
       error_message,
       provider_response,
       ctx.stale_created_at,
       ctx.stale_created_at
from p1_11a_context ctx
cross join lateral (
  values
    (
      ctx.uncertain_attempt_id,
      ctx.uncertain_gym_id,
      ctx.uncertain_user_id,
      'p1_11a_uncertain_order',
      'charge_failed',
      'pending',
      'TOSS_CHARGE_NETWORK_UNCERTAIN',
      'network dropped after approval',
      '{"mode":"initial_billing_charge_uncertain","billingKeyIssued":true}'::jsonb
    ),
    (
      ctx.fallback_attempt_id,
      ctx.fallback_gym_id,
      ctx.fallback_user_id,
      'p1_11a_fallback_order',
      'auth_issued',
      'none',
      null::text,
      null::text,
      '{"mode":"billing_key_issued"}'::jsonb
    )
) as attempts_to_insert(
  attempt_id,
  gym_id,
  user_id,
  order_id,
  attempt_status,
  recovery_status,
  error_code,
  error_message,
  provider_response
);

create temp table p1_11a_claimed on commit drop as
select *
from public.claim_stale_initial_billing_reconciliation_attempts(
  now() - interval '10 minutes',
  50
);

insert into p1_11a_test_results
select
  'TEST 1: uncertain charge_failed pending attempt is claimed',
  case when exists (
    select 1
    from p1_11a_claimed c
    join p1_11a_context ctx on ctx.uncertain_attempt_id = c.id
    where c.status = 'charge_failed'
      and c.recovery_status = 'pending'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_11a_claimed), '[]');

insert into p1_11a_test_results
select
  'TEST 2: uncertain attempt blocks a new initial charge',
  case when r.result->>'can_charge' = 'false'
     and (
       select count(*)
       from public.payment_attempts pa
       where pa.gym_id = ctx.uncertain_gym_id
         and pa.payment_type = 'initial_billing'
     ) = 1
    then 'PASS' else 'FAIL' end,
  r.result::text
from p1_11a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.uncertain_gym_id,
  ctx.uncertain_user_id,
  ctx.customer_key,
  10000
) r(result);

insert into p1_11a_test_results
select
  'TEST 3: auth_issued fallback blocks a new initial charge if uncertainty update fails',
  case when r.result->>'can_charge' = 'false'
     and r.result->>'action' = 'processing'
     and (
       select count(*)
       from public.payment_attempts pa
       where pa.gym_id = ctx.fallback_gym_id
         and pa.payment_type = 'initial_billing'
     ) = 1
    then 'PASS' else 'FAIL' end,
  r.result::text
from p1_11a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.fallback_gym_id,
  ctx.fallback_user_id,
  ctx.customer_key,
  10000
) r(result);

insert into p1_11a_test_results
select
  'TEST 4: auth_issued fallback is still eligible for stale reconciliation',
  case when exists (
    select 1
    from p1_11a_claimed c
    join p1_11a_context ctx on ctx.fallback_attempt_id = c.id
    where c.status = 'auth_issued'
      and c.recovery_status = 'pending'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_11a_claimed), '[]');

-- Simulate reconcile-initial-billing-payments finding a DONE Toss payment by orderId.
update public.payment_attempts pa
set
  status = 'activation_pending',
  activation_status = 'pending',
  recovery_status = 'none',
  payment_key = 'p1_11a_payment_key',
  error_code = null,
  error_message = null,
  provider_response = provider_response || jsonb_build_object(
    'initial_reconciliation',
    jsonb_build_object(
      'result', 'payment_found',
      'order_id', pa.order_id
    ),
    'payment',
    jsonb_build_object(
      'paymentKey', 'p1_11a_payment_key',
      'orderId', pa.order_id,
      'status', 'DONE',
      'totalAmount', 10000
    )
  )
from p1_11a_context ctx
where pa.id = ctx.uncertain_attempt_id;

create temp table p1_11a_recovery_result on commit drop as
select public.recover_payment_attempt_activation(ctx.uncertain_attempt_id) as result
from p1_11a_context ctx;

insert into p1_11a_test_results
select
  'TEST 5: DONE lookup recovery activates Pro from the original attempt',
  case when rr.result->>'ok' = 'true'
     and g.plan_code = 'pro'
     and g.member_limit = -1
     and g.subscription_status = 'active'
     and g.current_period_end = ctx.period_end
     and pa.status = 'completed'
     and pa.activation_status = 'succeeded'
     and pa.recovery_status = 'completed'
     and pa.payment_key = 'p1_11a_payment_key'
     and exists (
       select 1
       from public.subscriptions s
       where s.gym_id = ctx.uncertain_gym_id
         and s.started_at = ctx.period_start
         and s.ends_at = ctx.period_end
         and s.provider_ref = 'p1_11a_payment_key'
     )
    then 'PASS' else 'FAIL' end,
  'result=' || rr.result::text
  || ', gym_period=' || coalesce(g.current_period_end::text, 'null')
  || ', attempt_status=' || coalesce(pa.status, 'null')
  || ', activation_status=' || coalesce(pa.activation_status, 'null')
  || ', recovery_status=' || coalesce(pa.recovery_status, 'null')
from p1_11a_context ctx
cross join p1_11a_recovery_result rr
join public.gyms g on g.id = ctx.uncertain_gym_id
join public.payment_attempts pa on pa.id = ctx.uncertain_attempt_id;

select test_name, status, detail
from p1_11a_test_results
order by test_name;

select
  1 / case
    when exists (select 1 from p1_11a_test_results where status = 'FAIL') then 0
    else 1
  end as p1_11a_assert_all_tests_passed;

rollback;
