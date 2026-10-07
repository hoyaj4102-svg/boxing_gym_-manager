-- =============================================================================
-- P1-5 calendar-month billing tests
-- =============================================================================
--
-- Purpose:
--   Verify calendar-month billing period calculation and payment_attempt based
--   activation without calling Toss or Edge Functions.
--
-- Safety:
--   - Does not call Toss APIs.
--   - Does not call Edge Functions.
--   - Inserts synthetic gyms/payment_attempts only inside this transaction.
--   - Rolls everything back at the end.
--   - Refuses to run the claim test if an existing real Toss subscription would
--     also be due for the fixed test p_now.
--
-- Run after applying:
--   1. payment_attempts.sql
--   2. p0_2_payment_claim.sql
--   3. p1_5_calendar_month_billing.sql

begin;

set local timezone to 'UTC';

create temp table p1_5_test_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_5_test_context (
  claim_gym_id uuid primary key,
  normal_gym_id uuid not null,
  recovery_gym_id uuid not null,
  cancel_activation_gym_id uuid not null,
  cancel_recovery_gym_id uuid not null,
  preserve_gym_id uuid not null,
  claim_start timestamptz not null,
  claim_now timestamptz not null,
  expected_end timestamptz not null,
  preserve_period_end timestamptz not null,
  amount_krw integer not null,
  normal_attempt_id uuid not null,
  recovery_attempt_id uuid not null,
  cancel_activation_attempt_id uuid not null,
  cancel_recovery_attempt_id uuid not null
) on commit drop;

insert into p1_5_test_context (
  claim_gym_id,
  normal_gym_id,
  recovery_gym_id,
  cancel_activation_gym_id,
  cancel_recovery_gym_id,
  preserve_gym_id,
  claim_start,
  claim_now,
  expected_end,
  preserve_period_end,
  amount_krw,
  normal_attempt_id,
  recovery_attempt_id,
  cancel_activation_attempt_id,
  cancel_recovery_attempt_id
)
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  '2026-01-31 00:00:00+00'::timestamptz,
  '2026-02-02 00:00:00+00'::timestamptz,
  '2026-02-28 00:00:00+00'::timestamptz,
  '2099-01-31 00:00:00+00'::timestamptz,
  10000,
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid()
);

create temp table p1_5_calendar_cases (
  period_start timestamptz primary key,
  expected_period_end timestamptz not null
) on commit drop;

insert into p1_5_calendar_cases (period_start, expected_period_end)
values
  ('2026-01-31 00:00:00+00'::timestamptz, '2026-02-28 00:00:00+00'::timestamptz),
  ('2026-02-28 00:00:00+00'::timestamptz, '2026-03-28 00:00:00+00'::timestamptz),
  ('2026-03-31 00:00:00+00'::timestamptz, '2026-04-30 00:00:00+00'::timestamptz),
  ('2026-04-30 00:00:00+00'::timestamptz, '2026-05-30 00:00:00+00'::timestamptz),
  ('2028-02-29 00:00:00+00'::timestamptz, '2028-03-29 00:00:00+00'::timestamptz);

with mismatches as (
  select
    period_start,
    expected_period_end,
    public.billing_period_end(period_start, 'monthly') as actual_period_end
  from p1_5_calendar_cases
  where public.billing_period_end(period_start, 'monthly') <> expected_period_end
)
insert into p1_5_test_results (test_name, status, detail)
select
  'TEST A: calendar month helper',
  case when not exists (select 1 from mismatches) then 'PASS' else 'FAIL' end,
  coalesce(
    (
      select string_agg(
        period_start::text || ' expected ' || expected_period_end::text || ' got ' || actual_period_end::text,
        '; '
        order by period_start
      )
      from mismatches
    ),
    'all calendar-month cases matched'
  );

create temp table p1_5_due_conflicts on commit drop as
select count(*) as conflicting_due_count
from public.gyms g
join p1_5_test_context ctx on true
where g.billing_provider = 'toss'
  and g.auto_renew = true
  and g.subscription_status = 'active'
  and g.billing_customer_id is not null
  and g.billing_subscription_id is not null
  and g.current_period_end is not null
  and g.current_period_end <= ctx.claim_now;

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
  gym_name,
  'P1-5 Test',
  '',
  plan_code,
  member_limit,
  subscription_status,
  current_period_end,
  billing_provider,
  billing_customer_id,
  billing_subscription_id,
  auto_renew
from p1_5_test_context ctx
cross join lateral (
  values
    (
      ctx.claim_gym_id,
      '__p1_5_claim_test__',
      'pro',
      -1,
      'active',
      ctx.claim_start,
      'toss',
      'p1_5_claim_customer_' || replace(ctx.claim_gym_id::text, '-', ''),
      'p1_5_claim_billing_' || replace(ctx.claim_gym_id::text, '-', ''),
      true
    ),
    (
      ctx.normal_gym_id,
      '__p1_5_normal_activation_test__',
      'free',
      20,
      'expired',
      null::timestamptz,
      'toss',
      null,
      null,
      false
    ),
    (
      ctx.recovery_gym_id,
      '__p1_5_recovery_activation_test__',
      'free',
      20,
      'expired',
      null::timestamptz,
      'toss',
      null,
      null,
      false
    ),
    (
      ctx.cancel_activation_gym_id,
      '__p1_5_cancel_activation_test__',
      'pro',
      -1,
      'canceled',
      ctx.claim_start,
      'toss',
      'p1_5_cancel_customer_' || replace(ctx.cancel_activation_gym_id::text, '-', ''),
      'p1_5_cancel_billing_' || replace(ctx.cancel_activation_gym_id::text, '-', ''),
      false
    ),
    (
      ctx.cancel_recovery_gym_id,
      '__p1_5_cancel_recovery_test__',
      'pro',
      -1,
      'canceled',
      ctx.claim_start,
      'toss',
      'p1_5_cancel_customer_' || replace(ctx.cancel_recovery_gym_id::text, '-', ''),
      'p1_5_cancel_billing_' || replace(ctx.cancel_recovery_gym_id::text, '-', ''),
      false
    ),
    (
      ctx.preserve_gym_id,
      '__p1_5_existing_period_preserve_test__',
      'pro',
      -1,
      'active',
      ctx.preserve_period_end,
      'toss',
      'p1_5_preserve_customer_' || replace(ctx.preserve_gym_id::text, '-', ''),
      'p1_5_preserve_billing_' || replace(ctx.preserve_gym_id::text, '-', ''),
      true
    )
) as gyms_to_insert(
  gym_id,
  gym_name,
  plan_code,
  member_limit,
  subscription_status,
  current_period_end,
  billing_provider,
  billing_customer_id,
  billing_subscription_id,
  auto_renew
);

create temp table p1_5_first_claim on commit drop as
select c.*
from p1_5_test_context ctx
join p1_5_due_conflicts dc on dc.conflicting_due_count = 0
cross join lateral public.claim_due_toss_subscription_charges(
  ctx.claim_now,
  1,
  ctx.amount_krw
) c;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST B: late cron anchor',
  case
    when (select count(*) from p1_5_first_claim) = 1
     and exists (
       select 1
       from p1_5_first_claim fc
       join p1_5_test_context ctx on ctx.claim_gym_id = fc.gym_id
       where fc.target_period_start = ctx.claim_start
         and fc.target_period_end = ctx.expected_end
     )
    then 'PASS'
    else 'FAIL'
  end,
  'claim_rows=' || (select count(*) from p1_5_first_claim)
  || ', preflight_conflicting_due_count=' || (
    select conflicting_due_count from p1_5_due_conflicts
  )
  || ', target_periods=' || coalesce(
    (
      select string_agg(target_period_start::text || ' -> ' || target_period_end::text, '; ')
      from p1_5_first_claim
    ),
    'none'
  );

create temp table p1_5_second_claim on commit drop as
select c.*
from p1_5_test_context ctx
join p1_5_due_conflicts dc on dc.conflicting_due_count = 0
cross join lateral public.claim_due_toss_subscription_charges(
  ctx.claim_now,
  1,
  ctx.amount_krw
) c;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST C1: duplicate claim returns no second row',
  case
    when (select count(*) from p1_5_second_claim) = 0
     and (
       select count(*)
       from public.payment_attempts pa
       join p1_5_test_context ctx on ctx.claim_gym_id = pa.gym_id
       where pa.payment_type = 'auto_renewal'
         and pa.target_period_start = ctx.claim_start
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'second_claim_rows=' || (select count(*) from p1_5_second_claim)
  || ', attempts_for_period=' || (
    select count(*)
    from public.payment_attempts pa
    join p1_5_test_context ctx on ctx.claim_gym_id = pa.gym_id
    where pa.payment_type = 'auto_renewal'
      and pa.target_period_start = ctx.claim_start
  );

create temp table p1_5_duplicate_insert on commit drop as
with duplicate_attempt as (
  insert into public.payment_attempts (
    gym_id,
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
    ctx.claim_gym_id,
    'toss',
    'auto_renewal',
    'monthly',
    ctx.amount_krw,
    'KRW',
    'p1_5_duplicate_' || replace(gen_random_uuid()::text, '-', ''),
    'p1_5_duplicate_customer',
    'p1_5_duplicate_billing',
    ctx.claim_start,
    ctx.expected_end,
    'initiated',
    'not_started',
    'none',
    jsonb_build_object('mode', 'p1_5_duplicate_index_test')
  from p1_5_test_context ctx
  where exists (select 1 from p1_5_first_claim)
  on conflict do nothing
  returning id
)
select *
from duplicate_attempt;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST C2: duplicate unique index protection',
  case
    when (select count(*) from p1_5_first_claim) = 1
     and (select count(*) from p1_5_duplicate_insert) = 0
    then 'PASS'
    else 'FAIL'
  end,
  'first_claim_rows=' || (select count(*) from p1_5_first_claim)
  || ', duplicate_insert_rows=' || (select count(*) from p1_5_duplicate_insert);

insert into public.payment_attempts (
  id,
  gym_id,
  provider,
  payment_type,
  billing_interval,
  amount_krw,
  currency,
  order_id,
  payment_key,
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
  attempt_id,
  gym_id,
  'toss',
  payment_type,
  'monthly',
  ctx.amount_krw,
  'KRW',
  'p1_5_' || attempt_label || '_order_' || replace(attempt_id::text, '-', ''),
  'p1_5_' || attempt_label || '_payment_' || replace(attempt_id::text, '-', ''),
  'p1_5_' || attempt_label || '_customer_' || replace(gym_id::text, '-', ''),
  'p1_5_' || attempt_label || '_billing_' || replace(gym_id::text, '-', ''),
  ctx.claim_start,
  ctx.expected_end,
  attempt_status,
  activation_status,
  recovery_status,
  jsonb_build_object('mode', 'p1_5_activation_test', 'label', attempt_label)
from p1_5_test_context ctx
cross join lateral (
  values
    (
      ctx.normal_attempt_id,
      ctx.normal_gym_id,
      'normal',
      'initial_billing',
      'activation_pending',
      'pending',
      'none'
    ),
    (
      ctx.recovery_attempt_id,
      ctx.recovery_gym_id,
      'recovery',
      'initial_billing',
      'activation_failed',
      'failed',
      'pending'
    ),
    (
      ctx.cancel_activation_attempt_id,
      ctx.cancel_activation_gym_id,
      'cancel_activation',
      'auto_renewal',
      'activation_pending',
      'pending',
      'none'
    ),
    (
      ctx.cancel_recovery_attempt_id,
      ctx.cancel_recovery_gym_id,
      'cancel_recovery',
      'auto_renewal',
      'activation_failed',
      'failed',
      'pending'
    )
) as attempts_to_insert(
  attempt_id,
  gym_id,
  attempt_label,
  payment_type,
  attempt_status,
  activation_status,
  recovery_status
);

create temp table p1_5_normal_activation_result on commit drop as
select public.activate_payment_attempt(ctx.normal_attempt_id) as result
from p1_5_test_context ctx;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST D: normal activation uses stored target period',
  case
    when r.result->>'ok' = 'true'
     and g.current_period_end = ctx.expected_end
     and exists (
       select 1
       from public.subscriptions s
       where s.gym_id = ctx.normal_gym_id
         and s.started_at = ctx.claim_start
         and s.ends_at = ctx.expected_end
     )
    then 'PASS'
    else 'FAIL'
  end,
  'result=' || r.result::text
  || ', gym_period=' || coalesce(g.current_period_end::text, 'null')
  || ', expected=' || ctx.expected_end::text
from p1_5_test_context ctx
cross join p1_5_normal_activation_result r
left join public.gyms g on g.id = ctx.normal_gym_id;

create temp table p1_5_recovery_activation_result on commit drop as
select public.recover_payment_attempt_activation(ctx.recovery_attempt_id) as result
from p1_5_test_context ctx;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST E: recovery activation uses stored target period',
  case
    when r.result->>'ok' = 'true'
     and g.current_period_end = ctx.expected_end
     and exists (
       select 1
       from public.subscriptions s
       where s.gym_id = ctx.recovery_gym_id
         and s.started_at = ctx.claim_start
         and s.ends_at = ctx.expected_end
     )
    then 'PASS'
    else 'FAIL'
  end,
  'result=' || r.result::text
  || ', gym_period=' || coalesce(g.current_period_end::text, 'null')
  || ', expected=' || ctx.expected_end::text
from p1_5_test_context ctx
cross join p1_5_recovery_activation_result r
left join public.gyms g on g.id = ctx.recovery_gym_id;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST F: normal and recovery period match',
  case
    when normal_gym.current_period_end = ctx.expected_end
     and recovery_gym.current_period_end = ctx.expected_end
     and normal_sub.ends_at = recovery_sub.ends_at
    then 'PASS'
    else 'FAIL'
  end,
  'normal_end=' || coalesce(normal_gym.current_period_end::text, 'null')
  || ', recovery_end=' || coalesce(recovery_gym.current_period_end::text, 'null')
  || ', normal_subscription_end=' || coalesce(normal_sub.ends_at::text, 'null')
  || ', recovery_subscription_end=' || coalesce(recovery_sub.ends_at::text, 'null')
from p1_5_test_context ctx
join public.gyms normal_gym on normal_gym.id = ctx.normal_gym_id
join public.gyms recovery_gym on recovery_gym.id = ctx.recovery_gym_id
left join lateral (
  select s.ends_at
  from public.subscriptions s
  where s.gym_id = ctx.normal_gym_id
  order by s.created_at desc
  limit 1
) normal_sub on true
left join lateral (
  select s.ends_at
  from public.subscriptions s
  where s.gym_id = ctx.recovery_gym_id
  order by s.created_at desc
  limit 1
) recovery_sub on true;

create temp table p1_5_cancel_activation_result on commit drop as
select public.activate_payment_attempt(ctx.cancel_activation_attempt_id) as result
from p1_5_test_context ctx;

create temp table p1_5_cancel_recovery_result on commit drop as
select public.recover_payment_attempt_activation(ctx.cancel_recovery_attempt_id) as result
from p1_5_test_context ctx;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST G: cancellation preservation',
  case
    when ar.result->>'ok' = 'true'
     and rr.result->>'ok' = 'true'
     and activation_gym.subscription_status = 'canceled'
     and activation_gym.auto_renew = false
     and activation_gym.current_period_end = ctx.expected_end
     and recovery_gym.subscription_status = 'canceled'
     and recovery_gym.auto_renew = false
     and recovery_gym.current_period_end = ctx.expected_end
    then 'PASS'
    else 'FAIL'
  end,
  'activation_result=' || ar.result::text
  || ', recovery_result=' || rr.result::text
  || ', activation_status=' || coalesce(activation_gym.subscription_status, 'null')
  || ', activation_auto_renew=' || coalesce(activation_gym.auto_renew::text, 'null')
  || ', recovery_status=' || coalesce(recovery_gym.subscription_status, 'null')
  || ', recovery_auto_renew=' || coalesce(recovery_gym.auto_renew::text, 'null')
from p1_5_test_context ctx
cross join p1_5_cancel_activation_result ar
cross join p1_5_cancel_recovery_result rr
left join public.gyms activation_gym on activation_gym.id = ctx.cancel_activation_gym_id
left join public.gyms recovery_gym on recovery_gym.id = ctx.cancel_recovery_gym_id;

insert into p1_5_test_results (test_name, status, detail)
select
  'TEST H: existing current_period_end preservation',
  case
    when g.current_period_end = ctx.preserve_period_end
    then 'PASS'
    else 'FAIL'
  end,
  'preserve_gym_current_period_end=' || coalesce(g.current_period_end::text, 'null')
  || ', expected=' || ctx.preserve_period_end::text
from p1_5_test_context ctx
join public.gyms g on g.id = ctx.preserve_gym_id;

select test_name, status, detail
from p1_5_test_results
order by test_name;

select
  1 / case
    when exists (select 1 from p1_5_test_results where status = 'FAIL') then 0
    else 1
  end as p1_5_assert_all_tests_passed;

rollback;
