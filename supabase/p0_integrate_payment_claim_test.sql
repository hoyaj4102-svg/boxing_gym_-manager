-- Combined billing checks on a disposable database.
-- The caller applies both SQL files first. This script rolls back.
-- Recommended apply order: payment-data SQL, then expired-plan claim SQL,
-- then functions. The other SQL order is also covered by the caller.

begin;

create temp table integrate_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table integrate_ctx (
  repay_gym uuid not null,
  repay_user uuid not null,
  diverge_gym uuid not null,
  rollback_a_gym uuid not null,
  rollback_a_user uuid not null,
  rollback_b_gym uuid not null,
  rollback_b_user uuid not null,
  rollback_c_gym uuid not null,
  rollback_c_user uuid not null
) on commit drop;

insert into integrate_ctx values (
  '00000000-0000-0000-0000-00000000c101',
  '00000000-0000-0000-0000-00000000c201',
  '00000000-0000-0000-0000-00000000c102',
  '00000000-0000-0000-0000-00000000c103',
  '00000000-0000-0000-0000-00000000c203',
  '00000000-0000-0000-0000-00000000c104',
  '00000000-0000-0000-0000-00000000c204',
  '00000000-0000-0000-0000-00000000c105',
  '00000000-0000-0000-0000-00000000c205'
);

insert into public.gyms (
  id, name, plan_code, member_limit, subscription_status,
  current_period_end, billing_provider, billing_customer_id,
  billing_subscription_id, auto_renew
)
select gym_id, gym_name, 'pro', -1, 'active', now() - interval '2 days',
       'toss', customer_key, credential, true
from integrate_ctx
cross join lateral (values
  (repay_gym, 'Integrate Repay', 'integrate_customer', 'integrate_legacy_key'),
  (rollback_a_gym, 'Integrate Rollback A', 'integrate_customer_a', 'integrate_rollback_a'),
  (rollback_b_gym, 'Integrate Rollback B', 'integrate_customer_b', 'integrate_rollback_b'),
  (rollback_c_gym, 'Integrate Rollback C', 'integrate_customer_c', 'integrate_rollback_c')
) as g(gym_id, gym_name, customer_key, credential);

insert into auth.users (id, email)
select user_id, email
from integrate_ctx
cross join lateral (values
  (repay_user, 'integrate-repay@example.test'),
  (rollback_a_user, 'integrate-a@example.test'),
  (rollback_b_user, 'integrate-b@example.test'),
  (rollback_c_user, 'integrate-c@example.test')
) as u(user_id, email);

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'Integrate Owner'
from integrate_ctx
cross join lateral (values
  (repay_user, repay_gym),
  (rollback_a_user, rollback_a_gym),
  (rollback_b_user, rollback_b_gym),
  (rollback_c_user, rollback_c_gym)
) as p(user_id, gym_id)
on conflict (id) do update
set gym_id = excluded.gym_id, name = excluded.name;

insert into public.payment_attempts (
  gym_id, user_id, provider, payment_type, billing_interval,
  amount_krw, currency, order_id, customer_key, billing_key_ref, payment_key,
  target_period_start, target_period_end, status, activation_status,
  recovery_status, provider_response
)
select
  repay_gym, repay_user, 'toss', 'initial_billing', 'monthly',
  10000, 'KRW', 'integrate_old_order', 'integrate_customer',
  'integrate_legacy_key', 'integrate_old_payment',
  now() - interval '40 days', now() - interval '2 days',
  'completed', 'succeeded', 'none',
  jsonb_build_object('billingKey', 'integrate_payload_secret', 'totalAmount', 10000)
from integrate_ctx;

insert into public.checkout_sessions (
  gym_id, user_id, provider, "interval", amount_krw, currency, status,
  order_id, raw
)
select
  repay_gym, repay_user, 'toss', 'monthly', 10000, 'KRW', 'completed',
  'integrate_checkout_order',
  jsonb_build_object('billingKey', 'integrate_payload_secret', 'totalAmount', 10000)
from integrate_ctx;

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw,
  started_at, ends_at, raw
)
select
  repay_gym, 'pro', 'expired', 'toss', 'integrate_old_payment', 10000,
  now() - interval '40 days', now() - interval '2 days',
  jsonb_build_object('billingKey', 'integrate_payload_secret', 'totalAmount', 10000)
from integrate_ctx;

select private.backfill_billing_credentials();

insert into integrate_results (test_name, status, detail)
select
  'legacy credential moves into private storage',
  case
    when public.read_gym_billing_credential(ctx.repay_gym) = 'integrate_legacy_key'
     and g.billing_subscription_id is null
     and pa.billing_key_ref is null
     and public.read_gym_billing_credential(ctx.rollback_a_gym) = 'integrate_rollback_a'
    then 'PASS' else 'FAIL'
  end,
  'compared'
from integrate_ctx ctx
join public.gyms g on g.id = ctx.repay_gym
join public.payment_attempts pa on pa.order_id = 'integrate_old_order';

insert into integrate_results (test_name, status, detail)
select
  'saved provider payloads are redacted and keep the amount',
  case
    when pa.provider_response->>'billingKey' = '[REDACTED]'
     and pa.provider_response->>'totalAmount' = '10000'
     and pa.provider_response::text not like '%integrate_payload_secret%'
     and cs.raw->>'billingKey' = '[REDACTED]'
     and cs.raw::text not like '%integrate_payload_secret%'
     and s.raw->>'billingKey' = '[REDACTED]'
     and s.raw->>'totalAmount' = '10000'
    then 'PASS' else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
join public.checkout_sessions cs on cs.order_id = 'integrate_checkout_order'
join public.subscriptions s on s.provider_ref = 'integrate_old_payment'
where pa.order_id = 'integrate_old_order';

do $$
declare
  v_name text;
  v_sql text;
begin
  for v_name, v_sql in
    select *
    from (values
      ('owner cannot read gym credential', 'select billing_subscription_id from public.gyms'),
      ('owner cannot read attempt credential', 'select billing_key_ref from public.payment_attempts'),
      ('owner cannot read attempt payload', 'select provider_response from public.payment_attempts'),
      ('owner cannot read checkout payload', 'select raw from public.checkout_sessions'),
      ('owner cannot read subscription payload', 'select raw from public.subscriptions'),
      ('owner cannot read private storage', 'select billing_key from private.billing_credentials'),
      ('owner cannot execute credential read', 'select public.read_gym_billing_credential(null)'),
      ('owner cannot execute credential write', 'select public.upsert_gym_billing_credential(null, ''x'', ''toss'')')
    ) as checks(test_name, statement)
  loop
    begin
      execute 'set local role authenticated';
      execute v_sql;
      execute 'reset role';
      insert into integrate_results values (v_name, 'FAIL', 'statement succeeded');
    exception
      when insufficient_privilege then
        execute 'reset role';
        insert into integrate_results values (v_name, 'PASS', 'denied');
      when others then
        execute 'reset role';
        insert into integrate_results values (v_name, 'FAIL', sqlstate);
    end;
  end loop;
end
$$;

do $$
begin
  execute 'set local role authenticated';
  perform name from public.gyms where false;
  execute 'reset role';
  insert into integrate_results values (
    'owner can read a non-sensitive gym column', 'PASS', 'allowed'
  );
exception
  when others then
    execute 'reset role';
    insert into integrate_results values (
      'owner can read a non-sensitive gym column', 'FAIL', sqlstate
    );
end
$$;

do $$
declare
  v_actual text;
  v_gym uuid;
begin
  select repay_gym into v_gym from integrate_ctx;
  execute 'set local role service_role';
  select public.read_gym_billing_credential(v_gym) into v_actual;
  execute 'reset role';
  insert into integrate_results values (
    'service role can read stored credential',
    case when v_actual = 'integrate_legacy_key' then 'PASS' else 'FAIL' end,
    coalesce(v_actual, 'null')
  );
exception
  when others then
    execute 'reset role';
    insert into integrate_results values (
      'service role can read stored credential', 'FAIL', sqlstate
    );
end
$$;

create temp table integrate_repay_claim on commit drop as
select r.result
from integrate_ctx ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.repay_gym, ctx.repay_user, 'integrate_customer', 10000
) r(result);

update public.payment_attempts pa
set
  status = 'charge_succeeded',
  activation_status = 'pending',
  payment_key = 'integrate_new_payment'
from integrate_repay_claim claim
where pa.id = (claim.result->>'payment_attempt_id')::uuid;

select public.activate_payment_attempt_core(pa.id, false)
from public.payment_attempts pa
join integrate_repay_claim claim
  on pa.id = (claim.result->>'payment_attempt_id')::uuid;

create temp table integrate_repay_again on commit drop as
select r.result
from integrate_ctx ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.repay_gym, ctx.repay_user, 'integrate_customer', 10000
) r(result);

insert into integrate_results (test_name, status, detail)
select
  'expired pro can claim and repayment matches the payment record',
  case
    when claim.result->>'action' = 'charge'
     and claim.result->>'can_charge' = 'true'
     and claim.result->>'amount_krw' = '10000'
     and pa.amount_krw = 10000
     and pa.status = 'completed'
     and pa.activation_status = 'succeeded'
     and g.plan_code = 'pro'
     and g.subscription_status = 'active'
     and g.auto_renew = true
     and g.current_period_end = pa.target_period_end
     and g.current_period_end > now()
     and s.ends_at = pa.target_period_end
     and s.amount_krw = 10000
     and s.provider_ref = 'integrate_new_payment'
     and again.result->>'action' = 'already_completed'
     and again.result->>'can_charge' = 'false'
     and (again.result->>'current_period_end')::timestamptz = g.current_period_end
     and public.read_gym_billing_credential(ctx.repay_gym) = 'integrate_legacy_key'
     and g.billing_subscription_id is null
    then 'PASS' else 'FAIL'
  end,
  coalesce(claim.result->>'action', 'no-claim')
from integrate_ctx ctx
cross join integrate_repay_claim claim
cross join integrate_repay_again again
join public.payment_attempts pa
  on pa.id = (claim.result->>'payment_attempt_id')::uuid
join public.gyms g on g.id = ctx.repay_gym
join public.subscriptions s on s.provider_ref = 'integrate_new_payment';

insert into public.gyms (
  id, name, plan_code, member_limit, subscription_status,
  current_period_end, billing_provider, billing_customer_id,
  billing_subscription_id, auto_renew
)
select
  diverge_gym, 'Integrate Diverge', 'pro', -1, 'active',
  now() + interval '10 days', 'toss', 'integrate_customer_diverge',
  'integrate_stale_key', true
from integrate_ctx;

select public.upsert_gym_billing_credential(diverge_gym, 'integrate_kept_key', 'toss')
from integrate_ctx;

insert into public.payment_attempts (
  gym_id, user_id, provider, payment_type, billing_interval,
  amount_krw, currency, order_id, customer_key, billing_key_ref,
  target_period_start, target_period_end, status, activation_status, recovery_status
)
select gym_id, repay_user, 'toss', 'initial_billing', 'monthly',
       10000, 'KRW', order_id, 'integrate_customer_diverge', credential,
       now(), now() + interval '30 days', 'completed', 'succeeded', 'none'
from integrate_ctx
cross join lateral (values
  (diverge_gym, 'integrate_match_order', 'integrate_kept_key'),
  (diverge_gym, 'integrate_other_order', 'integrate_stale_key')
) as rows(gym_id, order_id, credential);

\ir p0_payment_data_protection.sql
\ir p1_15a_expired_pro_billing_claim.sql

insert into integrate_results (test_name, status, detail)
select
  'reapplying does not replace a stored credential or clear an uncopied value',
  case
    when public.read_gym_billing_credential(ctx.diverge_gym) = 'integrate_kept_key'
     and g.billing_subscription_id = 'integrate_stale_key'
     and matched.billing_key_ref is null
     and other.billing_key_ref = 'integrate_stale_key'
     and public.read_gym_billing_credential(ctx.repay_gym) = 'integrate_legacy_key'
     and repay.current_period_end > now()
     and repay_attempt.amount_krw = 10000
    then 'PASS' else 'FAIL'
  end,
  'compared'
from integrate_ctx ctx
join public.gyms g on g.id = ctx.diverge_gym
join public.gyms repay on repay.id = ctx.repay_gym
join public.payment_attempts matched on matched.order_id = 'integrate_match_order'
join public.payment_attempts other on other.order_id = 'integrate_other_order'
join public.payment_attempts repay_attempt on repay_attempt.payment_key = 'integrate_new_payment';

insert into integrate_results (test_name, status, detail)
select
  'reapplying the claim change still allows an expired plan to charge',
  case
    when r.result->>'action' = 'charge'
     and r.result->>'amount_krw' = '10000'
    then 'PASS' else 'FAIL'
  end,
  coalesce(r.result->>'action', 'no-claim')
from integrate_ctx ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.rollback_a_gym, ctx.rollback_a_user, 'integrate_customer_a', 10000
) r(result);

-- The claim above inserted an attempt. Remove it so later rollback checks
-- start from the same expired plan with no open attempt.
delete from public.payment_attempts pa
using integrate_ctx ctx
where pa.gym_id = ctx.rollback_a_gym
  and pa.payment_type = 'initial_billing'
  and pa.status = 'initiated';

create function pg_temp.assert_pass(p_name text)
returns void
language plpgsql
as $$
declare
  v_status text;
  v_detail text;
begin
  select status, detail into v_status, v_detail
  from integrate_results
  where test_name = p_name;
  if v_status is distinct from 'PASS' then
    raise exception 'INTEGRATION_TESTS_FAILED:%:%', p_name, coalesce(v_detail, 'missing');
  end if;
  raise notice 'PASS: % (%)', p_name, v_detail;
end
$$;

savepoint rollback_data_then_claim;

\ir p0_payment_data_protection_rollback.sql
\ir monthly_billing.sql
\ir p1_5_calendar_month_billing.sql

do $$
declare
  v_gym uuid;
  v_seen text;
begin
  select rollback_a_gym into v_gym from integrate_ctx;
  if not exists (
    select 1 from public.gyms
    where id = v_gym and billing_subscription_id = 'integrate_rollback_a'
  ) then
    insert into integrate_results values (
      'data rollback restores the previous credential copy', 'FAIL', 'value missing'
    );
    return;
  end if;

  insert into integrate_results values (
    'data rollback restores the previous credential copy', 'PASS', 'restored'
  );

  perform set_config('request.jwt.claim.sub', (select rollback_a_user::text from integrate_ctx), true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role authenticated';
  select billing_subscription_id into v_seen
  from public.gyms
  where id = v_gym;
  execute 'reset role';
  insert into integrate_results values (
    'data rollback restores owner read of the previous copy',
    case when v_seen = 'integrate_rollback_a' then 'PASS' else 'FAIL' end,
    coalesce(v_seen, 'null')
  );
exception
  when others then
    execute 'reset role';
    insert into integrate_results values (
      'data rollback restores owner read of the previous copy', 'FAIL', sqlstate
    );
end
$$;

select pg_temp.assert_pass('data rollback restores the previous credential copy');
select pg_temp.assert_pass('data rollback restores owner read of the previous copy');

insert into integrate_results (test_name, status, detail)
select
  'claim change remains after the data rollback',
  case
    when r.result->>'action' = 'charge'
     and r.result->>'amount_krw' = '10000'
    then 'PASS' else 'FAIL'
  end,
  coalesce(r.result->>'action', 'no-claim')
from integrate_ctx ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.rollback_b_gym, ctx.rollback_b_user, 'integrate_customer_b', 10000
) r(result);

select pg_temp.assert_pass('claim change remains after the data rollback');

delete from public.payment_attempts pa
using integrate_ctx ctx
where pa.gym_id = ctx.rollback_b_gym
  and pa.status = 'initiated';

\ir p1_15a_expired_pro_billing_claim_rollback.sql

insert into integrate_results (test_name, status, detail)
select
  'claim rollback restores the previous expired-plan result',
  case
    when r.result->>'action' = 'already_completed'
     and r.result->>'can_charge' = 'false'
    then 'PASS' else 'FAIL'
  end,
  coalesce(r.result->>'action', 'no-claim')
from integrate_ctx ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.rollback_b_gym, ctx.rollback_b_user, 'integrate_customer_b', 10000
) r(result);

select pg_temp.assert_pass('claim rollback restores the previous expired-plan result');

rollback to savepoint rollback_data_then_claim;

savepoint rollback_claim_then_data;

\ir p1_15a_expired_pro_billing_claim_rollback.sql

insert into integrate_results (test_name, status, detail)
select
  'claim rollback alone leaves private storage closed',
  case
    when r.result->>'action' = 'already_completed'
     and r.result->>'can_charge' = 'false'
     and public.read_gym_billing_credential(ctx.rollback_c_gym) = 'integrate_rollback_c'
     and g.billing_subscription_id is null
    then 'PASS' else 'FAIL'
  end,
  coalesce(r.result->>'action', 'no-claim')
from integrate_ctx ctx
join public.gyms g on g.id = ctx.rollback_c_gym
cross join lateral public.claim_initial_billing_attempt(
  ctx.rollback_c_gym, ctx.rollback_c_user, 'integrate_customer_c', 10000
) r(result);

select pg_temp.assert_pass('claim rollback alone leaves private storage closed');

do $$
begin
  execute 'set local role authenticated';
  perform billing_subscription_id from public.gyms where false;
  execute 'reset role';
  insert into integrate_results values (
    'owner still cannot read the credential before the data rollback',
    'FAIL',
    'statement succeeded'
  );
exception
  when insufficient_privilege then
    execute 'reset role';
    insert into integrate_results values (
      'owner still cannot read the credential before the data rollback',
      'PASS',
      'denied'
    );
  when others then
    execute 'reset role';
    insert into integrate_results values (
      'owner still cannot read the credential before the data rollback',
      'FAIL',
      sqlstate
    );
end
$$;

select pg_temp.assert_pass('owner still cannot read the credential before the data rollback');

\ir p0_payment_data_protection_rollback.sql
\ir p0_payment_data_protection_rollback.sql
\ir monthly_billing.sql
\ir p1_5_calendar_month_billing.sql

insert into integrate_results (test_name, status, detail)
select
  'either rollback order restores the previous copy once',
  case
    when g.billing_subscription_id = 'integrate_rollback_c'
     and r.result->>'action' = 'already_completed'
     and r.result->>'can_charge' = 'false'
    then 'PASS' else 'FAIL'
  end,
  coalesce(g.billing_subscription_id, 'null')
from integrate_ctx ctx
join public.gyms g on g.id = ctx.rollback_c_gym
cross join lateral public.claim_initial_billing_attempt(
  ctx.rollback_c_gym, ctx.rollback_c_user, 'integrate_customer_c', 10000
) r(result);

select pg_temp.assert_pass('either rollback order restores the previous copy once');

rollback to savepoint rollback_claim_then_data;

do $$
declare
  v_failed integer;
  v_row record;
begin
  select count(*) into v_failed
  from integrate_results
  where status <> 'PASS';

  for v_row in
    select test_name, status, detail
    from integrate_results
    order by test_name
  loop
    raise notice '%: % (%)', v_row.status, v_row.test_name, v_row.detail;
  end loop;

  if v_failed > 0 then
    raise exception 'INTEGRATION_TESTS_FAILED:%', v_failed;
  end if;
end
$$;

rollback;
