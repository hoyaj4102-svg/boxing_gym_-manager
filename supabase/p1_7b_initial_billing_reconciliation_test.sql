-- P1-7B initial billing reconciliation rollback tests.
-- Safe to paste into SQL Editor after applying:
--   1. p1_7_initial_billing_idempotency.sql
--   2. p1_7b_initial_billing_reconciliation.sql
-- This test never calls Toss and rolls back all synthetic data.

begin;

create temp table p1_7b_test_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_7b_context (
  stale_initiated_gym_id uuid not null,
  fresh_initiated_gym_id uuid not null,
  stale_auth_issued_gym_id uuid not null,
  stale_charge_failed_gym_id uuid not null,
  completed_gym_id uuid not null,
  payment_key_gym_id uuid not null,
  recent_pending_gym_id uuid not null,
  stale_pending_gym_id uuid not null,
  block_unresolved_gym_id uuid not null,
  confirmed_no_payment_gym_id uuid not null,
  completed_without_marker_gym_id uuid not null,
  active_gym_id uuid not null,
  canceled_entitled_gym_id uuid not null,
  historical_completed_gym_id uuid not null,
  customer_key text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  stale_created_at timestamptz not null,
  fresh_created_at timestamptz not null
) on commit drop;

insert into p1_7b_context
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
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  'p1_7b_customer',
  now() - interval '40 days',
  now() - interval '10 days',
  now() - interval '30 minutes',
  now()
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
select gym_id, name, 'P1-7B Owner', '010-0000-0000', plan_code, member_limit,
       subscription_status, current_period_end, billing_provider,
       billing_customer_id, billing_subscription_id, auto_renew
from p1_7b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id, 'P1-7B Stale Initiated Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.fresh_initiated_gym_id, 'P1-7B Fresh Initiated Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.stale_auth_issued_gym_id, 'P1-7B Stale Auth Issued Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.stale_charge_failed_gym_id, 'P1-7B Stale Charge Failed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.completed_gym_id, 'P1-7B Completed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.payment_key_gym_id, 'P1-7B Payment Key Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.recent_pending_gym_id, 'P1-7B Recent Pending Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.stale_pending_gym_id, 'P1-7B Stale Pending Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.block_unresolved_gym_id, 'P1-7B Block Unresolved Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.confirmed_no_payment_gym_id, 'P1-7B Confirmed No Payment Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.completed_without_marker_gym_id, 'P1-7B Completed Without Marker Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false),
    (ctx.active_gym_id, 'P1-7B Active Gym', 'pro', -1, 'active', now() + interval '30 days', 'toss', ctx.customer_key, 'p1_7b_billing_key_active', true),
    (ctx.canceled_entitled_gym_id, 'P1-7B Canceled Entitled Gym', 'pro', -1, 'canceled', now() + interval '30 days', 'toss', ctx.customer_key, 'p1_7b_billing_key_canceled', false),
    (ctx.historical_completed_gym_id, 'P1-7B Historical Completed Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false)
) as g(gym_id, name, plan_code, member_limit, subscription_status, current_period_end, billing_provider, billing_customer_id, billing_subscription_id, auto_renew);

create temp table p1_7b_gym_users on commit drop as
select gym_id, gen_random_uuid() as user_id
from p1_7b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id),
    (ctx.fresh_initiated_gym_id),
    (ctx.stale_auth_issued_gym_id),
    (ctx.stale_charge_failed_gym_id),
    (ctx.completed_gym_id),
    (ctx.payment_key_gym_id),
    (ctx.recent_pending_gym_id),
    (ctx.stale_pending_gym_id),
    (ctx.block_unresolved_gym_id),
    (ctx.confirmed_no_payment_gym_id),
    (ctx.completed_without_marker_gym_id),
    (ctx.active_gym_id),
    (ctx.canceled_entitled_gym_id),
    (ctx.historical_completed_gym_id)
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
  'p1_7b_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_7b_gym_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-7B Test User'
from p1_7b_gym_users
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

create function pg_temp.p1_7b_user_for(p_gym_id uuid)
returns uuid
language sql
stable
as $$
  select user_id
  from p1_7b_gym_users
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
  provider_response,
  created_at,
  updated_at
)
select
  gen_random_uuid(),
  gym_id,
  pg_temp.p1_7b_user_for(gym_id),
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
  attempt_status,
  activation_status,
  recovery_status,
  provider_response,
  created_at,
  updated_at
from p1_7b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id, 'p1_7b_stale_initiated_order', null::text, null::text, 'initiated', 'not_started', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.fresh_initiated_gym_id, 'p1_7b_fresh_initiated_order', null::text, null::text, 'initiated', 'not_started', 'none', '{}'::jsonb, ctx.fresh_created_at, ctx.fresh_created_at),
    (ctx.stale_auth_issued_gym_id, 'p1_7b_stale_auth_issued_order', 'p1_7b_billing_key_auth', null::text, 'auth_issued', 'not_started', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.stale_charge_failed_gym_id, 'p1_7b_stale_charge_failed_order', null::text, null::text, 'charge_failed', 'not_started', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.completed_gym_id, 'p1_7b_completed_order', 'p1_7b_billing_key_completed', 'p1_7b_payment_completed', 'completed', 'succeeded', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.payment_key_gym_id, 'p1_7b_payment_key_order', 'p1_7b_billing_key_payment', 'p1_7b_payment_key_existing', 'charge_succeeded', 'pending', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.recent_pending_gym_id, 'p1_7b_recent_pending_order', null::text, null::text, 'initiated', 'not_started', 'pending', '{}'::jsonb, ctx.stale_created_at, ctx.fresh_created_at),
    (ctx.stale_pending_gym_id, 'p1_7b_stale_pending_order', null::text, null::text, 'initiated', 'not_started', 'pending', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.block_unresolved_gym_id, 'p1_7b_block_unresolved_order', null::text, null::text, 'initiated', 'not_started', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.confirmed_no_payment_gym_id, 'p1_7b_confirmed_no_payment_order', null::text, null::text, 'charge_failed', 'not_started', 'completed', '{"initial_reconciliation":{"result":"confirmed_no_payment"}}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.completed_without_marker_gym_id, 'p1_7b_completed_without_marker_order', null::text, null::text, 'charge_failed', 'not_started', 'completed', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at),
    (ctx.historical_completed_gym_id, 'p1_7b_historical_completed_order', 'p1_7b_billing_key_history', 'p1_7b_payment_history', 'completed', 'succeeded', 'none', '{}'::jsonb, ctx.stale_created_at, ctx.stale_created_at)
) as pa(gym_id, order_id, billing_key_ref, payment_key, attempt_status, activation_status, recovery_status, provider_response, created_at, updated_at);

create temp table p1_7b_claimed on commit drop as
select *
from public.claim_stale_initial_billing_reconciliation_attempts(
  now() - interval '10 minutes',
  50
);

insert into p1_7b_test_results
select
  'TEST 1: stale initiated is claimed',
  case when exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.stale_initiated_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 2: fresh initiated is not claimed',
  case when not exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.fresh_initiated_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 3: stale auth_issued is claimed',
  case when exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.stale_auth_issued_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 4: stale charge_failed is claimed',
  case when exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.stale_charge_failed_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 5: completed succeeded is excluded',
  case when not exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.completed_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 6: existing payment_key is excluded',
  case when not exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.payment_key_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 7: recent recovery pending is not reclaimed',
  case when not exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.recent_pending_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 8: stale recovery pending can be reclaimed',
  case when exists (
    select 1
    from p1_7b_claimed c
    join p1_7b_context ctx on ctx.stale_pending_gym_id = c.gym_id
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id)::text from p1_7b_claimed), '[]');

insert into p1_7b_test_results
select
  'TEST 9: unresolved initial attempt still blocks new initial claim',
  case when r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.block_unresolved_gym_id, pg_temp.p1_7b_user_for(ctx.block_unresolved_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 10: confirmed_no_payment marker allows new initial claim',
  case when r.result->>'can_charge' = 'true'
         and r.result->>'action' = 'charge'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.confirmed_no_payment_gym_id, pg_temp.p1_7b_user_for(ctx.confirmed_no_payment_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 11: recovery_status completed without marker still blocks',
  case when r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.completed_without_marker_gym_id, pg_temp.p1_7b_user_for(ctx.completed_without_marker_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 12: active paid Pro still blocks',
  case when r.result->>'action' = 'already_completed'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.active_gym_id, pg_temp.p1_7b_user_for(ctx.active_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 13: canceled paid future entitlement still blocks',
  case when r.result->>'action' = 'already_completed'
         and r.result->>'can_charge' = 'false'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.canceled_entitled_gym_id, pg_temp.p1_7b_user_for(ctx.canceled_entitled_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 14: historical completed succeeded still allows new claim',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_7b_context ctx
cross join lateral public.claim_initial_billing_attempt(ctx.historical_completed_gym_id, pg_temp.p1_7b_user_for(ctx.historical_completed_gym_id), ctx.customer_key, 10000) r(result);

insert into p1_7b_test_results
select
  'TEST 15: RPC permissions expectation',
  case when has_function_privilege('public', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('anon', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('authenticated', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('service_role', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = true
       then 'PASS' else 'FAIL' end,
  jsonb_build_object(
    'public', has_function_privilege('public', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'anon', has_function_privilege('anon', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'authenticated', has_function_privilege('authenticated', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'service_role', has_function_privilege('service_role', 'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)', 'EXECUTE')
  )::text;

select *
from p1_7b_test_results
order by test_name;

rollback;
