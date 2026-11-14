-- P1-20 consent tests. Synthetic rows only, rolled back. No payment provider calls.
-- Each write is committed to this transaction in its own statement before the
-- assertion reads it. Postgres does not show a function's insert to another
-- function in the same statement.

begin;

create temp table p1_17_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_17_ctx (
  user_a uuid,
  user_b uuid,
  gym_a uuid,
  gym_b uuid,
  schedule_future uuid,
  schedule_effective uuid
) on commit drop;

create temp table p1_17_last (
  payload jsonb
) on commit drop;

insert into p1_17_ctx default values;

insert into p1_17_results
select
  'window includes the day 30 days before and excludes the conversion instant',
  case
    when public.billing_consent_in_window(
      '2025-05-02 00:00:00+09'::timestamptz,
      '2025-06-01 00:00:00+09'::timestamptz
    )
    and public.billing_consent_in_window(
      '2025-05-31 23:59:00+09'::timestamptz,
      '2025-06-01 00:00:00+09'::timestamptz
    )
    and not public.billing_consent_in_window(
      '2025-05-01 23:59:00+09'::timestamptz,
      '2025-06-01 00:00:00+09'::timestamptz
    )
    and not public.billing_consent_in_window(
      '2025-06-01 00:00:00+09'::timestamptz,
      '2025-06-01 00:00:00+09'::timestamptz
    )
    then 'PASS' else 'FAIL'
  end,
  'ftc-window';

do $$
begin
  insert into public.billing_price_schedules (
    plan_code, amount_before_krw, amount_after_krw, effective_at
  ) values ('pro', 10000, 10000, now() + interval '10 days');
  insert into p1_17_results
  values ('equal price is not an increase schedule', 'FAIL', 'insert succeeded');
exception when check_violation then
  insert into p1_17_results
  values ('equal price is not an increase schedule', 'PASS', 'check_violation');
end;
$$;

with inserted as (
  insert into auth.users (id, email, raw_user_meta_data)
  values (
    gen_random_uuid(),
    'consent-a@example.test',
    '{"gym_name":"Synthetic Consent Gym A","owner_name":"Synthetic","phone":""}'::jsonb
  )
  returning id
)
update p1_17_ctx
set user_a = (select id from inserted);

with inserted as (
  insert into auth.users (id, email, raw_user_meta_data)
  values (
    gen_random_uuid(),
    'consent-b@example.test',
    '{"gym_name":"Synthetic Consent Gym B","owner_name":"Synthetic","phone":""}'::jsonb
  )
  returning id
)
update p1_17_ctx
set user_b = (select id from inserted);

update p1_17_ctx
set
  gym_a = (select gym_id from public.profiles where id = p1_17_ctx.user_a),
  gym_b = (select gym_id from public.profiles where id = p1_17_ctx.user_b);

select set_config('app.allow_billing_update', '1', true);

update public.gyms
set
  subscription_status = 'trialing',
  trial_ends_at = now() + interval '10 days'
where id = (select gym_a from p1_17_ctx);

select set_config('request.jwt.claim.sub', (select user_a::text from p1_17_ctx), true);
select set_config('request.jwt.claim.role', 'authenticated', true);

insert into p1_17_results
select
  'renewal of the catalog price does not require a fresh checkbox',
  case
    when public.billing_charge_consent_gate(gym_a, 10000, 'renewal')->>'code' = 'OK'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 10000, 'renewal')->>'code'
from p1_17_ctx;

insert into p1_17_results
select
  'initial charge without consent is blocked',
  case
    when public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
      = 'PRE_PAYMENT_CONSENT_REQUIRED'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
from p1_17_ctx;

insert into p1_17_last
select public.record_billing_consent('pre_payment', 'grant', null);

insert into p1_17_results
select
  'pre-payment alone does not satisfy the trial conversion consent',
  case
    when (select payload->>'code' from p1_17_last) = 'RECORDED'
     and public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
       = 'TRIAL_CONSENT_REQUIRED'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
from p1_17_ctx;

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent('trial_to_paid', 'grant', null);

insert into p1_17_results
select
  'trial consent inside the open window is stored as zero to 10000',
  case
    when payload->>'code' = 'RECORDED'
     and consent.amount_before_krw = 0
     and consent.amount_after_krw = 10000
     and consent.schedule_id is null
     and consent.cancellation_method = '요금제 화면의 해지 버튼으로 해지합니다. 해지 후 다음 결제일부터 자동결제가 중단되고, 이미 결제한 이용 종료일까지 Pro를 사용할 수 있습니다.'
     and consent.policy_version = 'draft-2026-11-12'
    then 'PASS' else 'FAIL'
  end,
  coalesce(payload->>'code', 'missing')
from p1_17_last
left join public.billing_consents consent
  on consent.id = (payload->>'consent_id')::uuid;

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent('trial_to_paid', 'decline', null);

insert into p1_17_results
select
  'a later decline removes the trial grant',
  case
    when (select payload->>'code' from p1_17_last) = 'RECORDED'
     and public.billing_subject_granted(gym_a, 'trial_to_paid', trial_ends_at, null) = false
    then 'PASS' else 'FAIL'
  end,
  case
    when public.billing_subject_granted(gym_a, 'trial_to_paid', trial_ends_at, null)
    then 'still-granted' else 'not-granted'
  end
from p1_17_ctx
join public.gyms on gyms.id = p1_17_ctx.gym_a;

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent('trial_to_paid', 'grant', null);

insert into p1_17_results
select
  'granting again allows the initial charge',
  case
    when (select payload->>'code' from p1_17_last) = 'RECORDED'
     and public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'allowed' = 'true'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
from p1_17_ctx;

update public.gyms
set trial_ends_at = now() + interval '40 days'
where id = (select gym_a from p1_17_ctx);

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent('trial_to_paid', 'grant', null);

insert into p1_17_results
select
  'trial consent is rejected before the 30-day window',
  case
    when (select payload->>'code' from p1_17_last) = 'WINDOW_NOT_OPEN'
     and (public.get_billing_readiness()->'trial'->>'window_open') = 'false'
    then 'PASS' else 'FAIL'
  end,
  (select payload->>'code' from p1_17_last)
from p1_17_ctx;

update public.gyms
set trial_ends_at = now() - interval '1 hour'
where id = (select gym_a from p1_17_ctx);

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent('trial_to_paid', 'grant', null);

insert into p1_17_results
select
  'trial consent is rejected after conversion',
  case
    when (select payload->>'code' from p1_17_last) = 'WINDOW_CLOSED'
    then 'PASS' else 'FAIL'
  end,
  (select payload->>'code' from p1_17_last)
from p1_17_ctx;

update public.gyms
set trial_ends_at = now() + interval '10 days'
where id = (select gym_a from p1_17_ctx);

insert into p1_17_results
select
  'an unchanged catalog amount is not authorized as a new price',
  case
    when public.billing_charge_consent_gate(gym_a, 12000, 'renewal')->>'code'
      = 'PRICE_NOT_AUTHORIZED'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 12000, 'renewal')->>'code'
from p1_17_ctx;

with inserted as (
  insert into public.billing_price_schedules (
    plan_code, amount_before_krw, amount_after_krw, effective_at
  ) values (
    'pro', 10000, 12000, now() + interval '10 days'
  )
  returning id
)
update p1_17_ctx
set schedule_future = (select id from inserted);

delete from p1_17_last;
insert into p1_17_last
select public.record_billing_consent(
  'price_increase',
  'grant',
  (select schedule_future from p1_17_ctx)
);

insert into p1_17_results
select
  'price increase consent copies the schedule amounts',
  case
    when payload->>'code' = 'RECORDED'
     and consent.amount_before_krw = 10000
     and consent.amount_after_krw = 12000
     and consent.schedule_id = (select schedule_future from p1_17_ctx)
    then 'PASS' else 'FAIL'
  end,
  coalesce(payload->>'code', 'missing')
from p1_17_last
left join public.billing_consents consent
  on consent.id = (payload->>'consent_id')::uuid;

insert into p1_17_results
select
  'the increased amount is not chargeable before its effective time',
  case
    when public.billing_charge_consent_gate(gym_a, 12000, 'renewal')->>'code'
      = 'PRICE_NOT_AUTHORIZED'
     and public.billing_charge_consent_gate(gym_a, 10000, 'renewal')->>'code' = 'OK'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 12000, 'renewal')->>'code'
from p1_17_ctx;

with inserted as (
  insert into public.billing_price_schedules (
    plan_code, amount_before_krw, amount_after_krw, effective_at
  ) values (
    'pro', 10000, 15000, now() - interval '1 day'
  )
  returning id
)
update p1_17_ctx
set schedule_effective = (select id from inserted);

insert into public.billing_consents (
  gym_id,
  user_id,
  consent_type,
  decision,
  policy_version,
  amount_before_krw,
  amount_after_krw,
  conversion_at,
  schedule_id,
  payment_method,
  cancellation_method,
  created_at
)
select
  gym_a,
  user_a,
  'price_increase',
  'grant',
  'draft-2026-11-12',
  10000,
  15000,
  (select effective_at from public.billing_price_schedules where id = schedule_effective),
  schedule_effective,
  'toss_card_auto_pay',
  '요금제 화면의 해지 버튼으로 해지합니다. 해지 후 다음 결제일부터 자동결제가 중단되고, 이미 결제한 이용 종료일까지 Pro를 사용할 수 있습니다.',
  now() - interval '5 days'
from p1_17_ctx;

insert into p1_17_results
select
  'an effective increase can be charged only after in-window consent',
  case
    when public.billing_charge_consent_gate(gym_a, 15000, 'renewal')->>'code' = 'OK'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 15000, 'renewal')->>'code'
from p1_17_ctx;

update public.billing_consents
set created_at = now() - interval '7 hours'
where gym_id = (select gym_a from p1_17_ctx)
  and consent_type = 'pre_payment';

insert into p1_17_results
select
  'stale pre-payment consent blocks the initial charge',
  case
    when public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
      = 'PRE_PAYMENT_CONSENT_REQUIRED'
    then 'PASS' else 'FAIL'
  end,
  public.billing_charge_consent_gate(gym_a, 10000, 'initial')->>'code'
from p1_17_ctx;

select set_config('request.jwt.claim.sub', (select user_b::text from p1_17_ctx), true);

insert into p1_17_results
select
  'another gym does not inherit consent',
  case
    when (public.get_billing_readiness()->'trial'->>'consent_status') = 'missing'
     and (public.get_billing_readiness()->'pre_payment'->>'latest_status') = 'missing'
    then 'PASS' else 'FAIL'
  end,
  coalesce(public.get_billing_readiness()->'trial'->>'consent_status', 'none')
from p1_17_ctx;

do $$
declare
  v_detail text := 'not-run';
  v_ok boolean := false;
  v_gym uuid;
  v_user uuid;
begin
  select gym_b, user_b into v_gym, v_user from p1_17_ctx;
  begin
    execute 'set local role authenticated';
    insert into public.billing_consents (
      gym_id, user_id, consent_type, decision, policy_version,
      payment_method, cancellation_method
    ) values (
      v_gym, v_user, 'pre_payment', 'grant', 'draft-2026-11-12',
      'toss_card_auto_pay', 'direct'
    );
    execute 'reset role';
    v_detail := 'insert succeeded';
  exception
    when insufficient_privilege then
      v_ok := true;
      v_detail := 'insufficient_privilege';
      execute 'reset role';
    when others then
      v_detail := sqlerrm;
      execute 'reset role';
  end;

  insert into p1_17_results
  values (
    'authenticated clients cannot insert consent rows directly',
    case when v_ok then 'PASS' else 'FAIL' end,
    v_detail
  );
end;
$$;

select test_name, status, detail
from p1_17_results
order by test_name;

select
  case
    when not exists (select 1 from p1_17_results where status <> 'PASS') then 1
    else 1 / (
      select count(*)
      from p1_17_results
      where status <> 'PASS'
        and false
    )
  end as p1_17_assert_all_tests_passed;

rollback;
