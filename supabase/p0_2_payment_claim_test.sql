-- =============================================================================
-- P0-2 payment claim safety tests
-- =============================================================================
--
-- Purpose:
--   Verify the P0-2 DB claim layer without calling Toss or Edge Functions.
--
-- Safety:
--   - Does not call Toss APIs.
--   - Does not call charge-subscriptions.
--   - Does not call confirm-billing-auth.
--   - Does not call activate_gym_pro().
--   - Does not call recover_payment_attempt_activation().
--   - Does not update existing gyms.
--   - Does not delete existing payment_attempts.
--   - Inserts one synthetic gym and synthetic payment_attempt rows only inside
--     this transaction, then rolls everything back.
--
-- Run after applying:
--   1. payment_attempts.sql
--   2. p0_2_payment_claim.sql
--
-- Note:
--   A true two-session concurrency test requires two database sessions sharing a
--   committed fixture, which is intentionally not included here to avoid leaving
--   production data behind. TEST 4 validates the same duplicate-claim invariant
--   that prevents a second worker from reaching Toss after a claim exists.

begin;

create temp table p0_2_claim_test_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p0_2_claim_test_context (
  gym_id uuid primary key,
  target_period_start timestamptz not null,
  claim_now timestamptz not null,
  amount_krw integer not null
) on commit drop;

insert into p0_2_claim_test_context (
  gym_id,
  target_period_start,
  claim_now,
  amount_krw
)
values (
  gen_random_uuid(),
  '1900-01-01 00:00:00+00'::timestamptz,
  '1900-01-31 00:00:00+00'::timestamptz,
  10000
);

-- Synthetic due gym. The very old target_period_start makes this row sort before
-- normal production subscriptions while p_limit = 1 keeps the test scoped to it.
insert into public.gyms (
  id,
  name,
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
  '__p0_2_claim_test__',
  'pro',
  -1,
  'active',
  target_period_start,
  'toss',
  'p0_2_test_customer_' || replace(gym_id::text, '-', ''),
  'p0_2_test_billing_key_' || replace(gym_id::text, '-', ''),
  true
from p0_2_claim_test_context;

create temp table p0_2_first_claim on commit drop as
select c.*
from p0_2_claim_test_context ctx
cross join public.claim_due_toss_subscription_charges(
  ctx.claim_now,
  1,
  ctx.amount_krw
) c;

insert into p0_2_claim_test_results (test_name, status, detail)
select
  'TEST 1: first claim',
  case
    when (select count(*) from p0_2_first_claim) = 1
     and (
       select count(*)
       from public.payment_attempts pa
       join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
       where pa.payment_type = 'auto_renewal'
         and pa.target_period_start = ctx.target_period_start
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'first_claim_rows=' || (select count(*) from p0_2_first_claim)
  || ', attempts_for_period=' || (
    select count(*)
    from public.payment_attempts pa
    join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
    where pa.payment_type = 'auto_renewal'
      and pa.target_period_start = ctx.target_period_start
  );

create temp table p0_2_second_claim on commit drop as
select c.*
from p0_2_claim_test_context ctx
cross join public.claim_due_toss_subscription_charges(
  ctx.claim_now,
  1,
  ctx.amount_krw
) c;

insert into p0_2_claim_test_results (test_name, status, detail)
select
  'TEST 2: duplicate claim',
  case
    when (select count(*) from p0_2_second_claim) = 0
     and (
       select count(*)
       from public.payment_attempts pa
       join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
       where pa.payment_type = 'auto_renewal'
         and pa.target_period_start = ctx.target_period_start
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'second_claim_rows=' || (select count(*) from p0_2_second_claim)
  || ', attempts_for_period=' || (
    select count(*)
    from public.payment_attempts pa
    join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
    where pa.payment_type = 'auto_renewal'
      and pa.target_period_start = ctx.target_period_start
  );

do $$
declare
  v_gym_id uuid;
  v_target_period_start timestamptz;
  v_duplicate_blocked boolean := false;
begin
  select gym_id, target_period_start
  into v_gym_id, v_target_period_start
  from p0_2_claim_test_context;

  begin
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
    values (
      v_gym_id,
      'toss',
      'auto_renewal',
      'monthly',
      10000,
      'KRW',
      'p0_2_duplicate_' || replace(gen_random_uuid()::text, '-', ''),
      'p0_2_duplicate_customer',
      'p0_2_duplicate_billing_key',
      v_target_period_start,
      v_target_period_start + interval '30 days',
      'initiated',
      'not_started',
      'none',
      jsonb_build_object('mode', 'p0_2_duplicate_index_test')
    );
  exception
    when unique_violation then
      v_duplicate_blocked := true;
  end;

  insert into p0_2_claim_test_results (test_name, status, detail)
  values (
    'TEST 3: unique protection',
    case when v_duplicate_blocked then 'PASS' else 'FAIL' end,
    case
      when v_duplicate_blocked then
        'unique index blocked duplicate (gym_id, auto_renewal, target_period_start)'
      else
        'duplicate insert unexpectedly succeeded'
    end
  );
end;
$$;

insert into p0_2_claim_test_results (test_name, status, detail)
select
  'TEST 4: concurrent claim invariant',
  case
    when (select count(*) from p0_2_first_claim) = 1
     and (select count(*) from p0_2_second_claim) = 0
     and (
       select count(*)
       from public.payment_attempts pa
       join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
       where pa.payment_type = 'auto_renewal'
         and pa.target_period_start = ctx.target_period_start
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'first_claim_rows=' || (select count(*) from p0_2_first_claim)
  || ', second_claim_rows=' || (select count(*) from p0_2_second_claim)
  || ', attempts_for_period=' || (
    select count(*)
    from public.payment_attempts pa
    join p0_2_claim_test_context ctx on ctx.gym_id = pa.gym_id
    where pa.payment_type = 'auto_renewal'
      and pa.target_period_start = ctx.target_period_start
  );

do $$
declare
  v_result record;
begin
  for v_result in
    select test_name, status, detail
    from p0_2_claim_test_results
    order by test_name
  loop
    raise notice '%: % (%)', v_result.test_name, v_result.status, v_result.detail;
  end loop;
end;
$$;

select test_name, status, detail
from p0_2_claim_test_results
order by test_name;

rollback;
