-- P1-9B auto-renewal reconciliation claim rollback tests.
-- Safe to paste into SQL Editor after applying:
--   1. payment_attempts.sql
--   2. p0_2_payment_claim.sql
--   3. p1_1_auto_renewal_reconciliation.sql
-- This test never calls Toss and rolls back all synthetic data.

begin;

create temp table p1_9b_test_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_9b_context (
  stale_initiated_gym_id uuid not null,
  stale_charge_failed_gym_id uuid not null,
  stale_activation_pending_gym_id uuid not null,
  stale_activation_failed_gym_id uuid not null,
  stale_recovery_pending_gym_id uuid not null,
  stale_charge_succeeded_gym_id uuid not null,
  completed_gym_id uuid not null,
  fresh_initiated_gym_id uuid not null,
  recent_pending_gym_id uuid not null,
  initiated_with_key_gym_id uuid not null,
  activation_pending_without_key_gym_id uuid not null,
  initial_billing_gym_id uuid not null,
  customer_key text not null,
  billing_key_ref text not null,
  period_start timestamptz not null,
  period_end timestamptz not null,
  stale_at timestamptz not null,
  fresh_at timestamptz not null
) on commit drop;

insert into p1_9b_context
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
  'p1_9b_customer',
  'p1_9b_billing_key',
  now() - interval '30 days',
  now(),
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
select
  gym_id,
  name,
  'P1-9B Owner',
  '010-0000-0000',
  'pro',
  -1,
  'active',
  ctx.period_start,
  'toss',
  ctx.customer_key,
  ctx.billing_key_ref,
  true
from p1_9b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id, 'P1-9B Stale Initiated Gym'),
    (ctx.stale_charge_failed_gym_id, 'P1-9B Stale Charge Failed Gym'),
    (ctx.stale_activation_pending_gym_id, 'P1-9B Stale Activation Pending Gym'),
    (ctx.stale_activation_failed_gym_id, 'P1-9B Stale Activation Failed Gym'),
    (ctx.stale_recovery_pending_gym_id, 'P1-9B Stale Recovery Pending Gym'),
    (ctx.stale_charge_succeeded_gym_id, 'P1-9B Stale Charge Succeeded Gym'),
    (ctx.completed_gym_id, 'P1-9B Completed Gym'),
    (ctx.fresh_initiated_gym_id, 'P1-9B Fresh Initiated Gym'),
    (ctx.recent_pending_gym_id, 'P1-9B Recent Pending Gym'),
    (ctx.initiated_with_key_gym_id, 'P1-9B Initiated With Key Gym'),
    (ctx.activation_pending_without_key_gym_id, 'P1-9B Activation Pending Without Key Gym'),
    (ctx.initial_billing_gym_id, 'P1-9B Initial Billing Gym')
) as g(gym_id, name);

create temp table p1_9b_gym_users on commit drop as
select gym_id, gen_random_uuid() as user_id
from p1_9b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id),
    (ctx.stale_charge_failed_gym_id),
    (ctx.stale_activation_pending_gym_id),
    (ctx.stale_activation_failed_gym_id),
    (ctx.stale_recovery_pending_gym_id),
    (ctx.stale_charge_succeeded_gym_id),
    (ctx.completed_gym_id),
    (ctx.fresh_initiated_gym_id),
    (ctx.recent_pending_gym_id),
    (ctx.initiated_with_key_gym_id),
    (ctx.activation_pending_without_key_gym_id),
    (ctx.initial_billing_gym_id)
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
  'p1_9b_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_9b_gym_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-9B Test User'
from p1_9b_gym_users
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

create function pg_temp.p1_9b_user_for(p_gym_id uuid)
returns uuid
language sql
stable
as $$
  select user_id
  from p1_9b_gym_users
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
  error_code,
  error_message,
  provider_response,
  created_at,
  updated_at
)
select
  gen_random_uuid(),
  gym_id,
  pg_temp.p1_9b_user_for(gym_id),
  'toss',
  payment_type,
  'monthly',
  10000,
  'KRW',
  order_id,
  ctx.customer_key,
  ctx.billing_key_ref,
  payment_key,
  ctx.period_start,
  ctx.period_end,
  attempt_status,
  activation_status,
  recovery_status,
  'P1_9B_PREVIOUS_ERROR',
  'previous error',
  '{}'::jsonb,
  created_at,
  updated_at
from p1_9b_context ctx
cross join lateral (
  values
    (ctx.stale_initiated_gym_id, 'auto_renewal', 'p1_9b_stale_initiated_order', null::text, 'initiated', 'not_started', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.stale_charge_failed_gym_id, 'auto_renewal', 'p1_9b_stale_charge_failed_order', null::text, 'charge_failed', 'not_started', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.stale_activation_pending_gym_id, 'auto_renewal', 'p1_9b_stale_activation_pending_order', 'p1_9b_payment_activation_pending', 'activation_pending', 'pending', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.stale_activation_failed_gym_id, 'auto_renewal', 'p1_9b_stale_activation_failed_order', 'p1_9b_payment_activation_failed', 'activation_failed', 'failed', 'pending', ctx.stale_at, ctx.stale_at),
    (ctx.stale_recovery_pending_gym_id, 'auto_renewal', 'p1_9b_stale_recovery_pending_order', 'p1_9b_payment_recovery_pending', 'recovery_pending', 'pending', 'pending', ctx.stale_at, ctx.stale_at),
    (ctx.stale_charge_succeeded_gym_id, 'auto_renewal', 'p1_9b_stale_charge_succeeded_order', 'p1_9b_payment_charge_succeeded', 'charge_succeeded', 'pending', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.completed_gym_id, 'auto_renewal', 'p1_9b_completed_order', 'p1_9b_payment_completed', 'completed', 'succeeded', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.fresh_initiated_gym_id, 'auto_renewal', 'p1_9b_fresh_initiated_order', null::text, 'initiated', 'not_started', 'none', ctx.fresh_at, ctx.fresh_at),
    (ctx.recent_pending_gym_id, 'auto_renewal', 'p1_9b_recent_pending_order', null::text, 'initiated', 'not_started', 'pending', ctx.stale_at, ctx.fresh_at),
    (ctx.initiated_with_key_gym_id, 'auto_renewal', 'p1_9b_initiated_with_key_order', 'p1_9b_payment_initiated_with_key', 'initiated', 'not_started', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.activation_pending_without_key_gym_id, 'auto_renewal', 'p1_9b_activation_pending_without_key_order', null::text, 'activation_pending', 'pending', 'none', ctx.stale_at, ctx.stale_at),
    (ctx.initial_billing_gym_id, 'initial_billing', 'p1_9b_initial_billing_order', null::text, 'initiated', 'not_started', 'none', ctx.stale_at, ctx.stale_at)
) as pa(gym_id, payment_type, order_id, payment_key, attempt_status, activation_status, recovery_status, created_at, updated_at);

create temp table p1_9b_claimed on commit drop as
select *
from public.claim_stale_auto_renewal_reconciliation_attempts(
  now() - interval '10 minutes',
  50
);

insert into p1_9b_test_results
select
  'TEST 1: expected recoverable attempts are claimed',
  case when (
    select array_agg(c.order_id order by c.order_id)
    from p1_9b_claimed c
  ) = array[
    'p1_9b_stale_activation_failed_order',
    'p1_9b_stale_activation_pending_order',
    'p1_9b_stale_charge_failed_order',
    'p1_9b_stale_charge_succeeded_order',
    'p1_9b_stale_initiated_order',
    'p1_9b_stale_recovery_pending_order'
  ] then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 2: completed succeeded attempt is excluded',
  case when not exists (
    select 1
    from p1_9b_claimed
    where order_id = 'p1_9b_completed_order'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 3: fresh attempt is excluded',
  case when not exists (
    select 1
    from p1_9b_claimed
    where order_id = 'p1_9b_fresh_initiated_order'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 4: recently claimed pending attempt is excluded',
  case when not exists (
    select 1
    from p1_9b_claimed
    where order_id = 'p1_9b_recent_pending_order'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 5: payment_key polarity is enforced',
  case when not exists (
    select 1
    from p1_9b_claimed
    where order_id in (
      'p1_9b_initiated_with_key_order',
      'p1_9b_activation_pending_without_key_order'
    )
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 6: initial billing path is not affected',
  case when not exists (
    select 1
    from p1_9b_claimed
    where order_id = 'p1_9b_initial_billing_order'
  ) then 'PASS' else 'FAIL' end,
  coalesce((select json_agg(order_id order by order_id)::text from p1_9b_claimed), '[]');

insert into p1_9b_test_results
select
  'TEST 7: claimed attempts are marked pending and errors cleared',
  case when not exists (
    select 1
    from p1_9b_claimed c
    join public.payment_attempts pa on pa.id = c.id
    where pa.recovery_status <> 'pending'
       or pa.error_code is not null
       or pa.error_message is not null
       or pa.provider_response #>> '{reconciliation,status}' <> 'claimed'
  ) then 'PASS' else 'FAIL' end,
  coalesce((
    select json_agg(jsonb_build_object(
      'order_id', pa.order_id,
      'recovery_status', pa.recovery_status,
      'error_code', pa.error_code,
      'reconciliation', pa.provider_response -> 'reconciliation'
    ) order by pa.order_id)::text
    from p1_9b_claimed c
    join public.payment_attempts pa on pa.id = c.id
  ), '[]');

insert into p1_9b_test_results
select
  'TEST 8: RPC return shape remains Edge-compatible',
  case when (
    select array_agg(attname::text order by attnum)
    from pg_attribute
    where attrelid = 'pg_temp.p1_9b_claimed'::regclass
      and attnum > 0
      and not attisdropped
  ) = array[
    'id',
    'gym_id',
    'order_id',
    'amount_krw',
    'customer_key',
    'billing_key_ref',
    'status',
    'activation_status',
    'recovery_status',
    'payment_key',
    'reconciliation_action',
    'target_period_start',
    'target_period_end',
    'created_at',
    'updated_at'
  ] then 'PASS' else 'FAIL' end,
  (
    select array_agg(attname::text order by attnum)::text
    from pg_attribute
    where attrelid = 'pg_temp.p1_9b_claimed'::regclass
      and attnum > 0
      and not attisdropped
  );

insert into p1_9b_test_results
select
  'TEST 9: reconciliation action classifies lookup vs recovery',
  case when (
    select array_agg(order_id order by order_id)
    from p1_9b_claimed
    where reconciliation_action = 'lookup_required'
  ) = array[
    'p1_9b_stale_charge_failed_order',
    'p1_9b_stale_initiated_order'
  ] and (
    select array_agg(order_id order by order_id)
    from p1_9b_claimed
    where reconciliation_action = 'recovery_only'
  ) = array[
    'p1_9b_stale_activation_failed_order',
    'p1_9b_stale_activation_pending_order',
    'p1_9b_stale_charge_succeeded_order',
    'p1_9b_stale_recovery_pending_order'
  ] then 'PASS' else 'FAIL' end,
  jsonb_build_object(
    'lookup_required', (
      select json_agg(order_id order by order_id)
      from p1_9b_claimed
      where reconciliation_action = 'lookup_required'
    ),
    'recovery_only', (
      select json_agg(order_id order by order_id)
      from p1_9b_claimed
      where reconciliation_action = 'recovery_only'
    )
  )::text;

insert into p1_9b_test_results
select
  'TEST 10: RPC permissions expectation',
  case when has_function_privilege('public', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('anon', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('authenticated', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = false
         and has_function_privilege('service_role', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE') = true
       then 'PASS' else 'FAIL' end,
  jsonb_build_object(
    'public', has_function_privilege('public', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'anon', has_function_privilege('anon', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'authenticated', has_function_privilege('authenticated', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE'),
    'service_role', has_function_privilege('service_role', 'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)', 'EXECUTE')
  )::text;

select *
from p1_9b_test_results
order by test_name;

rollback;
