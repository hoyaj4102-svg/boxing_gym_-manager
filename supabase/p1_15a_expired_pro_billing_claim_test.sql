-- P1-15A expired Pro billing claim regression.
-- Safe to paste into SQL Editor after p1_15a_expired_pro_billing_claim.sql.
-- This test never calls Toss and rolls back all synthetic rows.
-- It does not delete existing members or payment records.

begin;

create temp table p1_15a_test_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_15a_context (
  incident_gym_id uuid not null,
  auto_initiated_gym_id uuid not null,
  auto_charge_failed_gym_id uuid not null,
  auto_charge_succeeded_gym_id uuid not null,
  auto_activation_pending_gym_id uuid not null,
  auto_activation_failed_gym_id uuid not null,
  auto_recovery_pending_gym_id uuid not null,
  initial_initiated_gym_id uuid not null,
  initial_charge_succeeded_gym_id uuid not null,
  initial_activation_failed_gym_id uuid not null,
  initial_recovery_pending_gym_id uuid not null,
  initial_completed_gym_id uuid not null,
  future_active_gym_id uuid not null,
  future_canceled_gym_id uuid not null,
  future_past_due_gym_id uuid not null,
  trial_gym_id uuid not null,
  customer_key text not null,
  period_start timestamptz not null,
  expired_period_end timestamptz not null,
  future_period_end timestamptz not null
) on commit drop;

insert into p1_15a_context
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
  gen_random_uuid(),
  gen_random_uuid(),
  'p1_15a_customer',
  timestamptz '2026-09-28 00:00:00+00',
  timestamptz '2026-10-28 00:00:00+00',
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
  'P1-15A Owner',
  '010-0000-0000',
  plan_code,
  -1,
  subscription_status,
  current_period_end,
  billing_provider,
  case when billing_provider is null then null else ctx.customer_key end,
  billing_key_ref,
  auto_renew
from p1_15a_context ctx
cross join lateral (
  values
    (ctx.incident_gym_id, 'P1-15A Incident Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_incident', true),
    (ctx.auto_initiated_gym_id, 'P1-15A Auto Initiated Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_initiated', true),
    (ctx.auto_charge_failed_gym_id, 'P1-15A Auto Charge Failed Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_charge_failed', true),
    (ctx.auto_charge_succeeded_gym_id, 'P1-15A Auto Charge Succeeded Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_charge_succeeded', true),
    (ctx.auto_activation_pending_gym_id, 'P1-15A Auto Activation Pending Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_activation_pending', true),
    (ctx.auto_activation_failed_gym_id, 'P1-15A Auto Activation Failed Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_activation_failed', true),
    (ctx.auto_recovery_pending_gym_id, 'P1-15A Auto Recovery Pending Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_auto_recovery_pending', true),
    (ctx.initial_initiated_gym_id, 'P1-15A Initial Initiated Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_initial_initiated', true),
    (ctx.initial_charge_succeeded_gym_id, 'P1-15A Initial Charge Succeeded Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_initial_charge_succeeded', true),
    (ctx.initial_activation_failed_gym_id, 'P1-15A Initial Activation Failed Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_initial_activation_failed', true),
    (ctx.initial_recovery_pending_gym_id, 'P1-15A Initial Recovery Pending Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_initial_recovery_pending', true),
    (ctx.initial_completed_gym_id, 'P1-15A Initial Completed Gym', 'pro', 'active', ctx.expired_period_end, 'toss', 'p1_15a_key_initial_completed', true),
    (ctx.future_active_gym_id, 'P1-15A Future Active Gym', 'pro', 'active', ctx.future_period_end, 'toss', 'p1_15a_key_future_active', true),
    (ctx.future_canceled_gym_id, 'P1-15A Future Canceled Gym', 'pro', 'canceled', ctx.future_period_end, 'toss', 'p1_15a_key_future_canceled', false),
    (ctx.future_past_due_gym_id, 'P1-15A Future Past Due Gym', 'pro', 'past_due', ctx.future_period_end, 'toss', 'p1_15a_key_future_past_due', true),
    (ctx.trial_gym_id, 'P1-15A Trial Gym', 'pro', 'trialing', null::timestamptz, null::text, null::text, false)
) as g(gym_id, name, plan_code, subscription_status, current_period_end, billing_provider, billing_key_ref, auto_renew);

create temp table p1_15a_gym_snapshot on commit drop as
select id, plan_code, subscription_status, auto_renew, current_period_end
from public.gyms
where id in (
  select incident_gym_id from p1_15a_context
  union all select auto_initiated_gym_id from p1_15a_context
  union all select auto_charge_failed_gym_id from p1_15a_context
  union all select auto_charge_succeeded_gym_id from p1_15a_context
  union all select auto_activation_pending_gym_id from p1_15a_context
  union all select auto_activation_failed_gym_id from p1_15a_context
  union all select auto_recovery_pending_gym_id from p1_15a_context
  union all select initial_initiated_gym_id from p1_15a_context
  union all select initial_charge_succeeded_gym_id from p1_15a_context
  union all select initial_activation_failed_gym_id from p1_15a_context
  union all select initial_recovery_pending_gym_id from p1_15a_context
  union all select initial_completed_gym_id from p1_15a_context
  union all select future_active_gym_id from p1_15a_context
  union all select future_canceled_gym_id from p1_15a_context
  union all select future_past_due_gym_id from p1_15a_context
  union all select trial_gym_id from p1_15a_context
);

create temp table p1_15a_gym_users on commit drop as
select gym_id, gen_random_uuid() as user_id
from (
  select incident_gym_id as gym_id from p1_15a_context
  union all select auto_initiated_gym_id from p1_15a_context
  union all select auto_charge_failed_gym_id from p1_15a_context
  union all select auto_charge_succeeded_gym_id from p1_15a_context
  union all select auto_activation_pending_gym_id from p1_15a_context
  union all select auto_activation_failed_gym_id from p1_15a_context
  union all select auto_recovery_pending_gym_id from p1_15a_context
  union all select initial_initiated_gym_id from p1_15a_context
  union all select initial_charge_succeeded_gym_id from p1_15a_context
  union all select initial_activation_failed_gym_id from p1_15a_context
  union all select initial_recovery_pending_gym_id from p1_15a_context
  union all select initial_completed_gym_id from p1_15a_context
  union all select future_active_gym_id from p1_15a_context
  union all select future_canceled_gym_id from p1_15a_context
  union all select future_past_due_gym_id from p1_15a_context
  union all select trial_gym_id from p1_15a_context
) gyms;

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
  'p1_15a_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_15a_gym_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-15A Test User'
from p1_15a_gym_users
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

create function pg_temp.p1_15a_user_for(p_gym_id uuid)
returns uuid
language sql
stable
as $$
  select user_id
  from p1_15a_gym_users
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
  pg_temp.p1_15a_user_for(gym_id),
  'toss',
  payment_type,
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
from p1_15a_context ctx
cross join lateral (
  values
    (ctx.auto_initiated_gym_id, 'auto_renewal', 'p1_15a_auto_initiated_order', 'p1_15a_key_auto_initiated', null::text, 'initiated', 'not_started', 'none'),
    (ctx.auto_charge_failed_gym_id, 'auto_renewal', 'p1_15a_auto_charge_failed_order', 'p1_15a_key_auto_charge_failed', null::text, 'charge_failed', 'not_started', 'none'),
    (ctx.auto_charge_succeeded_gym_id, 'auto_renewal', 'p1_15a_auto_charge_succeeded_order', 'p1_15a_key_auto_charge_succeeded', 'p1_15a_payment_auto_charge_succeeded', 'charge_succeeded', 'pending', 'none'),
    (ctx.auto_activation_pending_gym_id, 'auto_renewal', 'p1_15a_auto_activation_pending_order', 'p1_15a_key_auto_activation_pending', 'p1_15a_payment_auto_activation_pending', 'activation_pending', 'pending', 'none'),
    (ctx.auto_activation_failed_gym_id, 'auto_renewal', 'p1_15a_auto_activation_failed_order', 'p1_15a_key_auto_activation_failed', 'p1_15a_payment_auto_activation_failed', 'activation_failed', 'failed', 'pending'),
    (ctx.auto_recovery_pending_gym_id, 'auto_renewal', 'p1_15a_auto_recovery_pending_order', 'p1_15a_key_auto_recovery_pending', 'p1_15a_payment_auto_recovery_pending', 'recovery_pending', 'pending', 'pending'),
    (ctx.initial_initiated_gym_id, 'initial_billing', 'p1_15a_initial_initiated_order', 'p1_15a_key_initial_initiated', null::text, 'initiated', 'not_started', 'none'),
    (ctx.initial_charge_succeeded_gym_id, 'initial_billing', 'p1_15a_initial_charge_succeeded_order', 'p1_15a_key_initial_charge_succeeded', 'p1_15a_payment_initial_charge_succeeded', 'charge_succeeded', 'pending', 'none'),
    (ctx.initial_activation_failed_gym_id, 'initial_billing', 'p1_15a_initial_activation_failed_order', 'p1_15a_key_initial_activation_failed', 'p1_15a_payment_initial_activation_failed', 'activation_failed', 'failed', 'pending'),
    (ctx.initial_recovery_pending_gym_id, 'initial_billing', 'p1_15a_initial_recovery_pending_order', 'p1_15a_key_initial_recovery_pending', 'p1_15a_payment_initial_recovery_pending', 'recovery_pending', 'pending', 'pending'),
    (ctx.initial_completed_gym_id, 'initial_billing', 'p1_15a_initial_completed_order', 'p1_15a_key_initial_completed', 'p1_15a_payment_initial_completed', 'completed', 'succeeded', 'none')
) as pa(gym_id, payment_type, order_id, billing_key_ref, payment_key, attempt_status, activation_status, recovery_status);

create temp table p1_15a_seeded_attempt_ids on commit drop as
select id
from public.payment_attempts
where gym_id in (select gym_id from p1_15a_gym_users);

create temp table p1_15a_incident_first on commit drop as
select r.result
from p1_15a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.incident_gym_id,
  pg_temp.p1_15a_user_for(ctx.incident_gym_id),
  ctx.customer_key,
  10000
) r(result);

create temp table p1_15a_incident_second on commit drop as
select r.result
from p1_15a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.incident_gym_id,
  pg_temp.p1_15a_user_for(ctx.incident_gym_id),
  ctx.customer_key,
  10000
) r(result);

insert into p1_15a_test_results
select
  'TEST 1: expired active auto_renew Pro claims a new charge',
  case when result->>'action' = 'charge'
         and result->>'can_charge' = 'true'
         and coalesce(result->>'already_completed', 'false') <> 'true'
         and result->>'current_period_end' is null
       then 'PASS' else 'FAIL' end,
  result::text
from p1_15a_incident_first;

insert into p1_15a_test_results
select
  'TEST 2: expired incident claim inserts one initiated initial_billing attempt',
  case when count(*) = 1
         and bool_and(pa.status = 'initiated')
         and bool_and(pa.payment_type = 'initial_billing')
         and bool_and(pa.id = (select (result->>'payment_attempt_id')::uuid from p1_15a_incident_first))
       then 'PASS' else 'FAIL' end,
  count(*)::text
from public.payment_attempts pa
join p1_15a_context ctx on ctx.incident_gym_id = pa.gym_id;

insert into p1_15a_test_results
select
  'TEST 3: second claim on the same expired gym does not create another attempt',
  case when second.result->>'action' = 'processing'
         and second.result->>'can_charge' = 'false'
         and second.result->>'payment_attempt_id' = first.result->>'payment_attempt_id'
         and (
           select count(*)
           from public.payment_attempts pa
           join p1_15a_context ctx on ctx.incident_gym_id = pa.gym_id
         ) = 1
       then 'PASS' else 'FAIL' end,
  second.result::text
from p1_15a_incident_first first
cross join p1_15a_incident_second second;

insert into p1_15a_test_results
select
  test_name,
  case when r.result->>'action' = expected_action
         and r.result->>'can_charge' = 'false'
         and coalesce(r.result->>'payment_type', 'initial_billing') = expected_type
         and coalesce(r.result->>'already_completed', 'false') <> 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_15a_context ctx
cross join lateral (
  values
    ('TEST 4: expired active auto_renew with auto_renewal initiated does not charge', ctx.auto_initiated_gym_id, 'do_not_charge', 'auto_renewal'),
    ('TEST 5: expired active auto_renew with auto_renewal charge_failed does not charge', ctx.auto_charge_failed_gym_id, 'do_not_charge', 'auto_renewal'),
    ('TEST 6: expired active auto_renew with auto_renewal charge_succeeded needs recovery', ctx.auto_charge_succeeded_gym_id, 'needs_recovery', 'auto_renewal'),
    ('TEST 7: expired active auto_renew with auto_renewal activation_pending needs recovery', ctx.auto_activation_pending_gym_id, 'needs_recovery', 'auto_renewal'),
    ('TEST 8: expired active auto_renew with auto_renewal activation_failed needs recovery', ctx.auto_activation_failed_gym_id, 'needs_recovery', 'auto_renewal'),
    ('TEST 9: expired active auto_renew with auto_renewal recovery_pending needs recovery', ctx.auto_recovery_pending_gym_id, 'needs_recovery', 'auto_renewal'),
    ('TEST 10: expired active auto_renew with initial_billing initiated stays processing', ctx.initial_initiated_gym_id, 'processing', 'initial_billing'),
    ('TEST 11: expired active auto_renew with paid initial_billing awaiting activation needs recovery', ctx.initial_charge_succeeded_gym_id, 'needs_recovery', 'initial_billing'),
    ('TEST 12: expired active auto_renew with initial activation_failed needs recovery', ctx.initial_activation_failed_gym_id, 'needs_recovery', 'initial_billing'),
    ('TEST 13: expired active auto_renew with initial recovery_pending needs recovery', ctx.initial_recovery_pending_gym_id, 'needs_recovery', 'initial_billing')
) as expected(test_name, gym_id, expected_action, expected_type)
cross join lateral public.claim_initial_billing_attempt(
  expected.gym_id,
  pg_temp.p1_15a_user_for(expected.gym_id),
  ctx.customer_key,
  10000
) r(result);

insert into p1_15a_test_results
select
  'TEST 14: historical completed initial_billing on an expired gym can claim again',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
         and coalesce(r.result->>'already_completed', 'false') <> 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_15a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.initial_completed_gym_id,
  pg_temp.p1_15a_user_for(ctx.initial_completed_gym_id),
  ctx.customer_key,
  10000
) r(result);

insert into p1_15a_test_results
select
  test_name,
  case when r.result->>'action' = 'already_completed'
         and r.result->>'can_charge' = 'false'
         and (r.result->>'current_period_end')::timestamptz > now()
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_15a_context ctx
cross join lateral (
  values
    ('TEST 15: unexpired active auto_renew Pro is not charged again', ctx.future_active_gym_id),
    ('TEST 16: unexpired canceled Pro is not charged again', ctx.future_canceled_gym_id),
    ('TEST 17: unexpired past_due Pro keeps the paid-period block', ctx.future_past_due_gym_id)
) as expected(test_name, gym_id)
cross join lateral public.claim_initial_billing_attempt(
  expected.gym_id,
  pg_temp.p1_15a_user_for(expected.gym_id),
  ctx.customer_key,
  10000
) r(result);

insert into p1_15a_test_results
select
  'TEST 18: trialing Pro without a paid period can start billing',
  case when r.result->>'action' = 'charge'
         and r.result->>'can_charge' = 'true'
         and coalesce(r.result->>'already_completed', 'false') <> 'true'
       then 'PASS' else 'FAIL' end,
  r.result::text
from p1_15a_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.trial_gym_id,
  pg_temp.p1_15a_user_for(ctx.trial_gym_id),
  ctx.customer_key,
  10000
) r(result);

insert into p1_15a_test_results
select
  'TEST 19: blocking claims do not insert another payment attempt',
  case when not exists (
    select 1
    from public.payment_attempts pa
    where pa.gym_id in (
      select auto_initiated_gym_id from p1_15a_context
      union all select auto_charge_failed_gym_id from p1_15a_context
      union all select auto_charge_succeeded_gym_id from p1_15a_context
      union all select auto_activation_pending_gym_id from p1_15a_context
      union all select auto_activation_failed_gym_id from p1_15a_context
      union all select auto_recovery_pending_gym_id from p1_15a_context
      union all select initial_initiated_gym_id from p1_15a_context
      union all select initial_charge_succeeded_gym_id from p1_15a_context
      union all select initial_activation_failed_gym_id from p1_15a_context
      union all select initial_recovery_pending_gym_id from p1_15a_context
      union all select future_active_gym_id from p1_15a_context
      union all select future_canceled_gym_id from p1_15a_context
      union all select future_past_due_gym_id from p1_15a_context
    )
    and pa.id not in (select id from p1_15a_seeded_attempt_ids)
  ) then 'PASS' else 'FAIL' end,
  'checked';

insert into p1_15a_test_results
select
  'TEST 20: claims do not change gym plan, status, renewal, or period',
  case when not exists (
    select id, plan_code, subscription_status, auto_renew, current_period_end
    from public.gyms
    where id in (select id from p1_15a_gym_snapshot)
    except
    select id, plan_code, subscription_status, auto_renew, current_period_end
    from p1_15a_gym_snapshot
  ) then 'PASS' else 'FAIL' end,
  'checked';

select *
from p1_15a_test_results
order by test_name;

rollback;
