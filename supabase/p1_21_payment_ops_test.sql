-- P1-21 payment operations tests. Synthetic rows only, rolled back. No provider calls.

begin;

create temp table p1_18_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_18_ctx (
  user_id uuid,
  gym_id uuid,
  attempt_id uuid
) on commit drop;

insert into p1_18_ctx default values;

insert into p1_18_results
select
  'draft refund matches the seven-day full-refund rules',
  case
    when public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-11-08 00:00:00+00', 10000, 10000, 'customer_request', false
    )->>'code' = 'FULL_REFUND_WITHIN_7_DAYS'
    and public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-11-08 00:00:00.001+00', 10000, 10000, 'customer_request', false
    )->>'code' = 'REFUND_WINDOW_EXPIRED'
    and public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-11-02 00:00:00+00', 10000, 4000, 'customer_request', false
    )->>'code' = 'PARTIAL_REFUND_NOT_IN_DRAFT_POLICY'
    and public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-11-02 00:00:00+00', 10000, 10000, 'customer_request', true
    )->>'code' = 'NORMAL_USE_LIMIT'
    and public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-11-02 00:00:00+00', 10000, 10000, 'customer_request', null
    )->>'code' = 'NORMAL_USE_UNCONFIRMED'
    and public.evaluate_draft_refund(
      '2026-11-01 00:00:00+00', '2026-12-01 00:00:00+00', 10000, 10000, 'duplicate_charge', true
    )->>'code' = 'FULL_REFUND_DUPLICATE_OR_SYSTEM_ERROR'
    then 'PASS' else 'FAIL'
  end,
  'policy';

with inserted as (
  insert into auth.users (id, email, raw_user_meta_data)
  values (
    gen_random_uuid(),
    'ops-owner@example.test',
    '{"gym_name":"Synthetic Ops Gym","owner_name":"Synthetic","phone":""}'::jsonb
  )
  returning id
)
update p1_18_ctx set user_id = (select id from inserted);

update p1_18_ctx
set gym_id = (select gym_id from public.profiles where id = p1_18_ctx.user_id);

with inserted as (
  insert into public.payment_attempts (
    gym_id, user_id, provider, payment_type, amount_krw, order_id,
    payment_key, customer_key, status, activation_status, activated_at
  )
  select
    gym_id, user_id, 'toss', 'initial_billing', 10000, 'toss_bill_synthetic_refund',
    'pay_synthetic_refund', 'customer_synthetic', 'completed', 'succeeded',
    now() - interval '1 day'
  from p1_18_ctx
  returning id
)
update p1_18_ctx set attempt_id = (select id from inserted);

select set_config('request.jwt.claim.sub', (select user_id::text from p1_18_ctx), true);
select set_config('request.jwt.claim.role', 'authenticated', true);

create temp table p1_18_last (payload jsonb) on commit drop;

insert into p1_18_last
select public.create_billing_refund_request(
  (select attempt_id from p1_18_ctx), 'customer_request', 10000, false
);

insert into p1_18_results
select
  'owner refund request records a full unused refund without a provider call',
  case
    when (select payload->>'code' from p1_18_last) = 'FULL_REFUND_WITHIN_7_DAYS'
     and (select payload->>'allowed' from p1_18_last) = 'true'
     and request.provider_called = false
     and notice.email_status = 'disabled'
     and notice.sms_status = 'disabled'
    then 'PASS' else 'FAIL'
  end,
  coalesce((select payload->>'code' from p1_18_last), 'missing')
from p1_18_last
left join public.billing_refund_requests request
  on request.id = (payload->>'refund_request_id')::uuid
left join public.billing_notifications notice
  on notice.kind = 'refund_recorded';

insert into p1_18_results
select
  'a partial request is stored as denied',
  case
    when public.create_billing_refund_request(
      attempt_id, 'customer_request', 4000, false
    )->>'code' = 'PARTIAL_REFUND_NOT_IN_DRAFT_POLICY'
    then 'PASS' else 'FAIL'
  end,
  public.create_billing_refund_request(attempt_id, 'customer_request', 4000, false)->>'code'
from p1_18_ctx;

insert into p1_18_results
select
  'the owner status payload does not include the payment key',
  case
    when public.get_billing_ops_status()::text not like '%pay_synthetic_refund%'
     and public.get_billing_ops_status()::text not like '%payment_key%'
    then 'PASS' else 'FAIL'
  end,
  'redacted'
from p1_18_ctx;

delete from p1_18_last;
insert into p1_18_last
select public.record_payment_failure(
  (select gym_id from p1_18_ctx),
  (select attempt_id from p1_18_ctx),
  now(),
  'REJECT_CARD_COMPANY'
);

insert into p1_18_results
select
  'the first failure gets a 24 hour retry and a seven day grace',
  case
    when payload->>'state' = 'past_due'
     and (payload->>'next_retry_at')::timestamptz = (payload->>'grace_until')::timestamptz - interval '6 days'
     and payload->>'email' = 'disabled'
     and payload->>'sms' = 'disabled'
     and exists (
       select 1 from public.billing_notifications n
       where n.kind = 'payment_failed'
         and n.email_status = 'disabled'
         and n.sms_status = 'disabled'
     )
    then 'PASS' else 'FAIL'
  end,
  coalesce(payload->>'state', 'missing')
from p1_18_last;

insert into p1_18_results
select
  'a due retry can be claimed once',
  case
    when first_claim = 1 and second_claim = 0
    then 'PASS' else 'FAIL'
  end,
  'claim'
from (
  select
    (select count(*) from public.claim_due_payment_failure_retries(now() + interval '2 days', 10)) as first_claim,
    (select count(*) from public.claim_due_payment_failure_retries(now() + interval '2 days', 10)) as second_claim
) claims;

update public.payment_attempts
set provider_response = jsonb_build_object(
  'paymentKey', 'pay_from_payload',
  'receipt', jsonb_build_object('url', 'https://dashboard.tosspayments.com/receipt/stored')
)
where id = (select attempt_id from p1_18_ctx);

insert into p1_18_results
select
  'cancel key uses the payment_key column, not provider_response',
  case
    when public.resolve_attempt_payment_key(attempt_id) = 'pay_synthetic_refund'
    then 'PASS' else 'FAIL'
  end,
  'column'
from p1_18_ctx;

update public.payment_attempts
set payment_key = null
where id = (select attempt_id from p1_18_ctx);

insert into public.checkout_sessions (
  gym_id, user_id, provider, interval, amount_krw, order_id, provider_session_id, status, raw
)
select
  gym_id, user_id, 'toss', 'monthly', 10000, 'toss_bill_synthetic_refund',
  'pay_session_column', 'completed',
  jsonb_build_object('paymentKey', 'pay_from_payload')
from p1_18_ctx;

insert into p1_18_results
select
  'cancel key falls back to checkout provider_session_id',
  case
    when public.resolve_attempt_payment_key(attempt_id) = 'pay_session_column'
    then 'PASS' else 'FAIL'
  end,
  'session'
from p1_18_ctx;

delete from public.checkout_sessions
where order_id = 'toss_bill_synthetic_refund';

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw, raw
)
select
  gym_id, 'pro', 'active', 'toss', 'pay_sub_column', 10000,
  jsonb_build_object('paymentKey', 'pay_from_payload')
from p1_18_ctx;

insert into p1_18_results
select
  'cancel key falls back to the sole subscription provider_ref',
  case
    when public.resolve_attempt_payment_key(attempt_id) = 'pay_sub_column'
    then 'PASS' else 'FAIL'
  end,
  'subscription'
from p1_18_ctx;

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw
)
select gym_id, 'pro', 'active', 'toss', 'pay_sub_other', 10000
from p1_18_ctx;

insert into p1_18_results
select
  'ambiguous subscription refs are not used',
  case
    when public.resolve_attempt_payment_key(attempt_id) is null
    then 'PASS' else 'FAIL'
  end,
  'ambiguous'
from p1_18_ctx;

do $$
begin
  insert into public.billing_notifications (gym_id, kind, title, body, email_status, sms_status)
  select gym_id, 'payment_failed', 'x', 'y', 'sent', 'disabled' from p1_18_ctx;
  insert into p1_18_results values ('email status cannot be sent', 'FAIL', 'insert succeeded');
exception when check_violation then
  insert into p1_18_results values ('email status cannot be sent', 'PASS', 'check_violation');
end;
$$;

do $$
declare
  v_ok boolean := false;
  v_detail text := 'not-run';
  v_gym uuid;
  v_user uuid;
  v_request uuid;
begin
  select gym_id, user_id into v_gym, v_user from p1_18_ctx;
  select id into v_request from public.billing_refund_requests where gym_id = v_gym limit 1;
  begin
    execute 'set local role authenticated';
    perform public.load_billing_refund_for_cancel(v_gym, v_user, v_request);
    execute 'reset role';
    v_detail := 'call succeeded';
  exception
    when insufficient_privilege then
      v_ok := true;
      v_detail := 'insufficient_privilege';
      execute 'reset role';
    when others then
      v_detail := sqlerrm;
      execute 'reset role';
  end;
  insert into p1_18_results values (
    'authenticated clients cannot load a payment key',
    case when v_ok then 'PASS' else 'FAIL' end,
    v_detail
  );
end;
$$;

select test_name, status, detail
from p1_18_results
order by test_name;

select
  case
    when not exists (select 1 from p1_18_results where status <> 'PASS') then 1
    else 1 / (
      select count(*)
      from p1_18_results
      where status <> 'PASS'
        and false
    )
  end as p1_18_assert_all_tests_passed;

rollback;
