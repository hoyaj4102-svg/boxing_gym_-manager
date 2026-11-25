-- Payment data protection checks.
-- Run on a disposable database after supabase/p0_payment_data_protection.sql.
-- This script rolls back. It does not call a payment provider.

begin;

create temp table p0_payment_data_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p0_payment_data_context (
  gym_id uuid primary key,
  credential text not null,
  customer_key text not null,
  period_start timestamptz not null
) on commit drop;

insert into p0_payment_data_context (gym_id, credential, customer_key, period_start)
values (
  gen_random_uuid(),
  'p0_pd_credential',
  'p0_pd_customer',
  '1900-01-01 00:00:00+00'::timestamptz
);

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
  '__p0_payment_data_test__',
  'pro',
  -1,
  'active',
  period_start,
  'toss',
  customer_key,
  credential,
  true
from p0_payment_data_context;

select public.upsert_gym_billing_credential(gym_id, credential, 'toss')
from p0_payment_data_context;

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set billing_subscription_id = null
from p0_payment_data_context ctx
where g.id = ctx.gym_id;

create temp table p0_payment_data_claim on commit drop as
select c.*
from p0_payment_data_context ctx
cross join lateral public.claim_due_toss_subscription_charges(
  '1900-02-01 00:00:00+00'::timestamptz,
  1,
  10000
) c;

insert into p0_payment_data_results (test_name, status, detail)
select
  'service role claim returns credential without storing it',
  case
    when (select count(*) from p0_payment_data_claim) = 1
     and exists (
       select 1
       from p0_payment_data_claim claim
       join p0_payment_data_context ctx on ctx.gym_id = claim.gym_id
       where claim.billing_key_ref = ctx.credential
         and claim.amount_krw = 10000
     )
     and exists (
       select 1
       from public.payment_attempts pa
       join p0_payment_data_claim claim on claim.payment_attempt_id = pa.id
       where pa.billing_key_ref is null
         and pa.amount_krw = 10000
     )
    then 'PASS'
    else 'FAIL'
  end,
  'claim_rows=' || (select count(*) from p0_payment_data_claim);

insert into p0_payment_data_results (test_name, status, detail)
select
  'private read matches stored credential',
  case
    when public.read_gym_billing_credential(ctx.gym_id) = ctx.credential
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p0_payment_data_context ctx;

insert into public.payment_attempts (
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
  ctx.gym_id,
  'toss',
  'initial_billing',
  'monthly',
  10000,
  'KRW',
  'p0_pd_activate_order',
  'p0_pd_payment',
  ctx.customer_key,
  'p0_pd_rotated',
  now(),
  now() + interval '1 month',
  'charge_succeeded',
  'pending',
  'none',
  jsonb_build_object('billingKey', 'p0_pd_rotated', 'totalAmount', 10000)
from p0_payment_data_context ctx;

select public.activate_payment_attempt_core(pa.id, false)
from public.payment_attempts pa
where pa.order_id = 'p0_pd_activate_order';

insert into p0_payment_data_results (test_name, status, detail)
select
  'activation keeps credential private and preserves amount',
  case
    when pa.billing_key_ref is null
     and pa.amount_krw = 10000
     and pa.status = 'completed'
     and g.billing_subscription_id is null
     and public.read_gym_billing_credential(ctx.gym_id) = 'p0_pd_rotated'
     and s.provider_ref = 'p0_pd_payment'
     and s.amount_krw = 10000
     and s.raw::text not like '%p0_pd_rotated%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p0_payment_data_context ctx
join public.payment_attempts pa on pa.order_id = 'p0_pd_activate_order'
join public.gyms g on g.id = ctx.gym_id
join public.subscriptions s on s.gym_id = ctx.gym_id and s.provider_ref = 'p0_pd_payment';

do $$
declare
  v_name text;
  v_sql text;
begin
  for v_name, v_sql in
    select *
    from (values
      (
        'owner role cannot select gym credential column',
        'select billing_subscription_id from public.gyms'
      ),
      (
        'owner role cannot select attempt credential column',
        'select billing_key_ref from public.payment_attempts'
      ),
      (
        'owner role cannot select checkout payload',
        'select raw from public.checkout_sessions'
      ),
      (
        'owner role cannot read private credential storage',
        'select vault_secret_id from private.billing_credentials'
      ),
      (
        'owner role cannot execute credential read',
        'select public.read_gym_billing_credential(null)'
      )
    ) as checks(test_name, statement)
  loop
    begin
      execute 'set local role authenticated';
      execute v_sql;
      execute 'reset role';
      insert into p0_payment_data_results (test_name, status, detail)
      values (v_name, 'FAIL', 'statement succeeded');
    exception
      when insufficient_privilege then
        execute 'reset role';
        insert into p0_payment_data_results (test_name, status, detail)
        values (v_name, 'PASS', 'permission denied');
      when others then
        execute 'reset role';
        insert into p0_payment_data_results (test_name, status, detail)
        values (v_name, 'FAIL', sqlstate);
    end;
  end loop;
end;
$$;

do $$
begin
  begin
    execute 'set local role authenticated';
    perform name from public.gyms where false;
    execute 'reset role';
    insert into p0_payment_data_results (test_name, status, detail)
    values (
      'owner role can query a non-sensitive gym column',
      'PASS',
      'name column allowed'
    );
  exception
    when others then
      execute 'reset role';
      insert into p0_payment_data_results (test_name, status, detail)
      values (
        'owner role can query a non-sensitive gym column',
        'FAIL',
        sqlstate
      );
  end;
end;
$$;

do $$
declare
  v_gym_id uuid;
  v_expected text;
  v_actual text;
begin
  select gym_id into v_gym_id
  from p0_payment_data_context;
  select public.read_gym_billing_credential(v_gym_id) into v_expected;

  execute 'set local role service_role';
  select public.read_gym_billing_credential(v_gym_id) into v_actual;
  execute 'reset role';

  insert into p0_payment_data_results (test_name, status, detail)
  values (
    'service role can read stored credential',
    case when v_actual = v_expected then 'PASS' else 'FAIL' end,
    'compared'
  );
exception
  when others then
    execute 'reset role';
    insert into p0_payment_data_results (test_name, status, detail)
    values ('service role can read stored credential', 'FAIL', sqlstate);
end;
$$;

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
values
  (
    '00000000-0000-0000-0000-0000000000a1',
    '__p0_payment_data_legacy__',
    'pro',
    -1,
    'active',
    now() + interval '30 days',
    'toss',
    'p0_pd_legacy_customer',
    'p0_pd_legacy',
    true
  ),
  (
    '00000000-0000-0000-0000-0000000000a2',
    '__p0_payment_data_other_provider__',
    'pro',
    -1,
    'active',
    now() + interval '30 days',
    'stripe',
    'stripe_customer',
    'stripe_sub_keep',
    false
  );

select private.backfill_billing_credentials();

insert into p0_payment_data_results (test_name, status, detail)
select
  'approved backfill moves legacy credential and keeps other providers',
  case
    when not exists (
      select 1
      from public.gyms
      where id = '00000000-0000-0000-0000-0000000000a1'
        and billing_subscription_id is not null
    )
     and public.read_gym_billing_credential('00000000-0000-0000-0000-0000000000a1') = 'p0_pd_legacy'
     and exists (
       select 1
       from public.gyms
       where id = '00000000-0000-0000-0000-0000000000a2'
         and billing_subscription_id = 'stripe_sub_keep'
     )
     and public.read_gym_billing_credential('00000000-0000-0000-0000-0000000000a1') is distinct from
         public.read_gym_billing_credential('00000000-0000-0000-0000-0000000000a2')
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into p0_payment_data_results (test_name, status, detail)
select
  'payload sanitizer removes sensitive fields and keeps amount',
  case
    when redacted ->> 'billingKey' = '[REDACTED]'
     and redacted ->> 'customerEmail' = '[REDACTED]'
     and redacted ->> 'card' = '[REDACTED]'
     and redacted ->> 'totalAmount' = '10000'
     and redacted ->> 'billingKeyIssued' = 'true'
     and redacted::text not like '%p0_pd_credential%'
     and redacted::text not like '%4111111111111111%'
    then 'PASS'
    else 'FAIL'
  end,
  'redacted'
from (
  select private.redact_sensitive_payload(jsonb_build_object(
    'billingKey', ctx.credential,
    'card', jsonb_build_object('number', '4111111111111111'),
    'customerEmail', 'member@example.test',
    'totalAmount', 10000,
    'billingKeyIssued', true
  )) as redacted
  from p0_payment_data_context ctx
) payload;

do $$
declare
  v_result record;
  v_failed integer;
begin
  select count(*) into v_failed
  from p0_payment_data_results
  where status <> 'PASS';

  for v_result in
    select test_name, status
    from p0_payment_data_results
    order by test_name
  loop
    raise notice '%: %', v_result.status, v_result.test_name;
  end loop;

  if v_failed > 0 then
    raise exception 'PAYMENT_DATA_PROTECTION_TESTS_FAILED:%', v_failed;
  end if;
end;
$$;

rollback;
