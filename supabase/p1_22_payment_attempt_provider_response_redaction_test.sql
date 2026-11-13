-- Synthetic checks for payment_attempts.provider_response redaction.
-- This script rolls back. It does not use stored production payloads.
-- Rows inserted with the payload trigger disabled are the rows the rewrite masks.
-- Rows inserted with that trigger enabled must be masked on insert and update.

begin;

create temp table attempt_redaction_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create or replace function pg_temp.neighbor_digest()
returns text
language sql
stable
as $$
  select md5(concat_ws(E'\n',
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.checkout_sessions t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.subscriptions t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.gyms t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.profiles t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.members t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from public.toss_webhook_events t), 'empty'),
    coalesce((select md5(string_agg(t::text || t.xmin::text, '|' order by t.id::text)) from private.billing_credentials t), 'empty')
  ));
$$;

create or replace function pg_temp.attempt_columns_digest()
returns text
language sql
stable
as $$
  select coalesce(md5(string_agg(
    concat_ws('|',
      pa.id::text,
      pa.gym_id::text,
      coalesce(pa.user_id::text, ''),
      pa.provider,
      pa.payment_type,
      pa.billing_interval,
      pa.amount_krw::text,
      pa.currency,
      pa.order_id,
      coalesce(pa.payment_key, ''),
      coalesce(pa.customer_key, ''),
      coalesce(pa.billing_key_ref, ''),
      coalesce(pa.target_period_start::text, ''),
      coalesce(pa.target_period_end::text, ''),
      pa.status,
      pa.activation_status,
      pa.recovery_status,
      coalesce(pa.error_code, ''),
      coalesce(pa.error_message, ''),
      coalesce(pa.activated_at::text, ''),
      coalesce(pa.recovered_at::text, ''),
      pa.created_at::text,
      pa.updated_at::text
    ),
    E'\n' order by pa.order_id
  )), 'empty')
  from public.payment_attempts pa;
$$;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000d301', 'attempt-payload-fixture@example.test');

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set
  name = 'Synthetic Attempt Payload Gym',
  plan_code = 'pro',
  member_limit = -1,
  subscription_status = 'active',
  current_period_end = timestamptz '2026-02-15 00:00:00+00',
  billing_provider = 'toss',
  billing_customer_id = 'synthetic-customer',
  billing_subscription_id = 'synthetic-billing-key-value',
  auto_renew = true
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301'
  and g.id = p.gym_id;

insert into private.billing_credentials (gym_id, provider, billing_key)
select p.gym_id, 'toss', 'synthetic-billing-key-value'
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301';

alter table public.payment_attempts disable trigger payment_attempts_redact_payload;
alter table public.checkout_sessions disable trigger checkout_sessions_redact_payload;
alter table public.subscriptions disable trigger subscriptions_redact_payload;

insert into public.payment_attempts (
  gym_id,
  user_id,
  provider,
  payment_type,
  billing_interval,
  amount_krw,
  currency,
  order_id,
  payment_key,
  customer_key,
  billing_key_ref,
  status,
  activation_status,
  recovery_status,
  provider_response,
  created_at,
  updated_at
)
select
  p.gym_id,
  p.id,
  'toss',
  fixture.payment_type,
  'monthly',
  fixture.amount_krw,
  'KRW',
  fixture.order_id,
  fixture.payment_key,
  'synthetic-customer',
  'synthetic-legacy-billing-ref',
  fixture.status,
  fixture.activation_status,
  fixture.recovery_status,
  fixture.provider_response,
  timestamptz '2026-01-15 00:00:00+00',
  timestamptz '2026-01-15 00:00:00+00'
from public.profiles p
cross join (
  values
    (
      'initial_billing'::text,
      10000,
      'synthetic-attempt-nested'::text,
      'synthetic-nested-column-key'::text,
      'charge_succeeded'::text,
      'pending'::text,
      'none'::text,
      jsonb_build_object(
        'orderId', 'synthetic-attempt-nested',
        'status', 'DONE',
        'totalAmount', 10000,
        'approvedAt', '2026-01-15T00:00:00Z',
        'method', 'card',
        'billingKeyIssued', true,
        'payment', jsonb_build_object(
          'paymentKey', 'synthetic-nested-pay',
          'payment_key', 'synthetic-nested-pay-snake',
          'last_transaction_key', 'synthetic-nested-txn',
          'mId', 'synthetic-mid',
          'approveNo', 'synthetic-approval',
          'receipt', jsonb_build_object('url', 'https://example.test/receipt/nested'),
          'card', jsonb_build_object('number', 'synthetic-card-value'),
          'checkout_url', 'https://example.test/checkout/nested',
          'orderId', 'synthetic-attempt-nested',
          'totalAmount', 10000
        ),
        'events', jsonb_build_array(
          jsonb_build_object(
            'transactionKey', 'synthetic-event-txn',
            'note', 'synthetic-note',
            'customer_email', 'synthetic-member@example.test'
          )
        ),
        'initial_reconciliation', jsonb_build_object(
          'result', 'payment_found',
          'order_id', 'synthetic-attempt-nested'
        ),
        'reconciliation', jsonb_build_object('status', 'claimed')
      )
    ),
    (
      'auto_renewal',
      5000,
      'synthetic-attempt-clean',
      'synthetic-clean-column-key',
      'completed',
      'succeeded',
      'completed',
      jsonb_build_object(
        'orderId', 'synthetic-attempt-clean',
        'status', 'DONE',
        'totalAmount', 5000,
        'method', 'card',
        'paymentKey', '[REDACTED]',
        'initial_reconciliation', jsonb_build_object(
          'result', 'confirmed_no_payment',
          'order_id', 'synthetic-attempt-clean'
        )
      )
    )
) as fixture (
  payment_type,
  amount_krw,
  order_id,
  payment_key,
  status,
  activation_status,
  recovery_status,
  provider_response
)
where p.id = '00000000-0000-0000-0000-00000000d301';

insert into public.checkout_sessions (
  gym_id, user_id, provider, "interval", amount_krw, currency, status,
  order_id, provider_session_id, raw
)
select
  p.gym_id,
  p.id,
  'toss',
  'monthly',
  10000,
  'KRW',
  'completed',
  'synthetic-checkout-order',
  'synthetic-checkout-session',
  jsonb_build_object(
    'paymentKey', 'synthetic-checkout-pay',
    'orderId', 'synthetic-checkout-order',
    'totalAmount', 10000,
    'status', 'DONE'
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301';

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw, raw
)
select
  p.gym_id,
  'pro',
  'active',
  'toss',
  'synthetic-subscription-ref',
  10000,
  jsonb_build_object(
    'paymentKey', 'synthetic-subscription-pay',
    'orderId', 'synthetic-subscription-order',
    'totalAmount', 10000,
    'status', 'DONE'
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301';

alter table public.payment_attempts enable trigger payment_attempts_redact_payload;
alter table public.checkout_sessions enable trigger checkout_sessions_redact_payload;
alter table public.subscriptions enable trigger subscriptions_redact_payload;

create temp table state_before on commit drop as
select
  pg_temp.neighbor_digest() as neighbor_digest,
  pg_temp.attempt_columns_digest() as attempt_digest,
  (
    select pa.xmin::text
    from public.payment_attempts pa
    where pa.order_id = 'synthetic-attempt-clean'
  ) as clean_xmin,
  (
    select pa.provider_response::text
    from public.payment_attempts pa
    where pa.order_id = 'synthetic-attempt-clean'
  ) as clean_payload;

do $$
declare
  v_updated integer;
begin
  v_updated := private.apply_payment_attempt_provider_response_redaction();
  insert into attempt_redaction_results (test_name, status, detail)
  values (
    'first redaction updates only the nested payload',
    case when v_updated = 1 then 'PASS' else 'FAIL' end,
    'updated=' || coalesce(v_updated::text, 'null')
  );
end
$$;

insert into attempt_redaction_results (test_name, status, detail)
select
  'nested sensitive keys are masked',
  case
    when pa.provider_response #>> '{payment,paymentKey}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,payment_key}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,last_transaction_key}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,mId}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,approveNo}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,receipt}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,card}' = '[REDACTED]'
     and pa.provider_response #>> '{payment,checkout_url}' = '[REDACTED]'
     and pa.provider_response #>> '{events,0,transactionKey}' = '[REDACTED]'
     and pa.provider_response #>> '{events,0,customer_email}' = '[REDACTED]'
     and pa.provider_response::text not like '%synthetic-nested-pay%'
     and pa.provider_response::text not like '%synthetic-nested-txn%'
     and pa.provider_response::text not like '%synthetic-mid%'
     and pa.provider_response::text not like '%synthetic-approval%'
     and pa.provider_response::text not like '%example.test/receipt/nested%'
     and pa.provider_response::text not like '%example.test/checkout/nested%'
     and pa.provider_response::text not like '%synthetic-card-value%'
     and pa.provider_response::text not like '%synthetic-event-txn%'
     and pa.provider_response::text not like '%synthetic-member@example.test%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
where pa.order_id = 'synthetic-attempt-nested';

insert into attempt_redaction_results (test_name, status, detail)
select
  'non-sensitive keys and reconciliation markers stay',
  case
    when pa.provider_response ->> 'orderId' = 'synthetic-attempt-nested'
     and pa.provider_response ->> 'status' = 'DONE'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and pa.provider_response ->> 'method' = 'card'
     and pa.provider_response ->> 'billingKeyIssued' = 'true'
     and pa.provider_response #>> '{payment,orderId}' = 'synthetic-attempt-nested'
     and pa.provider_response #>> '{payment,totalAmount}' = '10000'
     and pa.provider_response #>> '{events,0,note}' = 'synthetic-note'
     and pa.provider_response #>> '{initial_reconciliation,result}' = 'payment_found'
     and pa.provider_response #>> '{initial_reconciliation,order_id}' = 'synthetic-attempt-nested'
     and pa.provider_response #>> '{reconciliation,status}' = 'claimed'
     and clean.provider_response ->> 'orderId' = 'synthetic-attempt-clean'
     and clean.provider_response ->> 'status' = 'DONE'
     and clean.provider_response ->> 'totalAmount' = '5000'
     and clean.provider_response ->> 'paymentKey' = '[REDACTED]'
     and clean.provider_response #>> '{initial_reconciliation,result}' = 'confirmed_no_payment'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
join public.payment_attempts clean on clean.order_id = 'synthetic-attempt-clean'
where pa.order_id = 'synthetic-attempt-nested';

insert into attempt_redaction_results (test_name, status, detail)
select
  'payment status amount and other columns stay',
  case
    when pg_temp.attempt_columns_digest() = state_before.attempt_digest
     and nested.status = 'charge_succeeded'
     and nested.amount_krw = 10000
     and nested.payment_key = 'synthetic-nested-column-key'
     and nested.billing_key_ref = 'synthetic-legacy-billing-ref'
     and nested.updated_at = timestamptz '2026-01-15 00:00:00+00'
     and clean.status = 'completed'
     and clean.amount_krw = 5000
     and clean.payment_key = 'synthetic-clean-column-key'
     and clean.xmin::text = state_before.clean_xmin
     and clean.provider_response::text = state_before.clean_payload
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from state_before
join public.payment_attempts nested on nested.order_id = 'synthetic-attempt-nested'
join public.payment_attempts clean on clean.order_id = 'synthetic-attempt-clean';

insert into attempt_redaction_results (test_name, status, detail)
select
  'other tables stay unchanged',
  case
    when pg_temp.neighbor_digest() = state_before.neighbor_digest
     and cs.raw ->> 'paymentKey' = 'synthetic-checkout-pay'
     and cs.raw ->> 'orderId' = 'synthetic-checkout-order'
     and cs.raw ->> 'totalAmount' = '10000'
     and cs.status = 'completed'
     and cs.amount_krw = 10000
     and s.raw ->> 'paymentKey' = 'synthetic-subscription-pay'
     and s.raw ->> 'orderId' = 'synthetic-subscription-order'
     and s.status = 'active'
     and s.amount_krw = 10000
     and s.provider_ref = 'synthetic-subscription-ref'
     and g.billing_subscription_id = 'synthetic-billing-key-value'
     and c.billing_key = 'synthetic-billing-key-value'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from state_before
join public.checkout_sessions cs on cs.order_id = 'synthetic-checkout-order'
join public.subscriptions s on s.provider_ref = 'synthetic-subscription-ref'
join public.profiles p on p.id = '00000000-0000-0000-0000-00000000d301'
join public.gyms g on g.id = p.gym_id
join private.billing_credentials c on c.gym_id = p.gym_id;

create temp table after_first on commit drop as
select
  pa.provider_response::text as payload,
  pa.xmin::text as xmin_text,
  pg_temp.attempt_columns_digest() as attempt_digest,
  pg_temp.neighbor_digest() as neighbor_digest
from public.payment_attempts pa
where pa.order_id = 'synthetic-attempt-nested';

do $$
declare
  v_updated integer;
begin
  v_updated := private.apply_payment_attempt_provider_response_redaction();
  insert into attempt_redaction_results (test_name, status, detail)
  values (
    'second redaction changes 0 rows',
    case when v_updated = 0 then 'PASS' else 'FAIL' end,
    'updated=' || coalesce(v_updated::text, 'null')
  );
end
$$;

insert into attempt_redaction_results (test_name, status, detail)
select
  'second redaction keeps the masked payload and leaves other rows',
  case
    when pa.provider_response::text = after_first.payload
     and pa.xmin::text = after_first.xmin_text
     and pg_temp.attempt_columns_digest() = after_first.attempt_digest
     and pg_temp.neighbor_digest() = after_first.neighbor_digest
     and clean.xmin::text = state_before.clean_xmin
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from after_first
join public.payment_attempts pa on pa.order_id = 'synthetic-attempt-nested'
join public.payment_attempts clean on clean.order_id = 'synthetic-attempt-clean'
join state_before on true;

insert into attempt_redaction_results (test_name, status, detail)
select
  'payload trigger covers insert and update of provider_response',
  case
    when position('BEFORE INSERT OR UPDATE OF provider_response' in trigger_def) > 0
     and position('redact_payment_row' in trigger_def) > 0
     and updated_at_trigger = 'O'
     and payload_trigger = 'O'
    then 'PASS'
    else 'FAIL'
  end,
  coalesce(trigger_def, 'missing')
from (
  select
    (
      select pg_get_triggerdef(t.oid)
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      join pg_namespace n on n.oid = c.relnamespace
      where t.tgname = 'payment_attempts_redact_payload'
        and n.nspname = 'public'
        and c.relname = 'payment_attempts'
        and not t.tgisinternal
    ) as trigger_def,
    (
      select t.tgenabled
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      where t.tgname = 'payment_attempts_set_updated_at'
        and c.relname = 'payment_attempts'
        and not t.tgisinternal
    ) as updated_at_trigger,
    (
      select t.tgenabled
      from pg_trigger t
      join pg_class c on c.oid = t.tgrelid
      where t.tgname = 'payment_attempts_redact_payload'
        and c.relname = 'payment_attempts'
        and not t.tgisinternal
    ) as payload_trigger
) triggers;

insert into public.payment_attempts (
  gym_id,
  user_id,
  provider,
  payment_type,
  billing_interval,
  amount_krw,
  currency,
  order_id,
  payment_key,
  customer_key,
  billing_key_ref,
  status,
  activation_status,
  recovery_status,
  provider_response,
  created_at,
  updated_at
)
select
  p.gym_id,
  p.id,
  'toss',
  'initial_billing',
  'monthly',
  10000,
  'KRW',
  'synthetic-attempt-trigger',
  'synthetic-trigger-column-key',
  'synthetic-customer',
  'synthetic-legacy-billing-ref',
  'initiated',
  'not_started',
  'none',
  jsonb_build_object(
    'paymentKey', 'synthetic-trigger-pay',
    'orderId', 'synthetic-attempt-trigger',
    'totalAmount', 10000,
    'nested', jsonb_build_object(
      'secret', 'synthetic-trigger-secret',
      'status', 'DONE'
    )
  ),
  timestamptz '2026-01-15 00:00:00+00',
  timestamptz '2026-01-15 00:00:00+00'
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301';

insert into attempt_redaction_results (test_name, status, detail)
select
  'new insert masks nested sensitive keys',
  case
    when pa.provider_response ->> 'paymentKey' = '[REDACTED]'
     and pa.provider_response #>> '{nested,secret}' = '[REDACTED]'
     and pa.provider_response #>> '{nested,status}' = 'DONE'
     and pa.provider_response ->> 'orderId' = 'synthetic-attempt-trigger'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response::text not like '%synthetic-trigger-pay%'
     and pa.provider_response::text not like '%synthetic-trigger-secret%'
     and pa.status = 'initiated'
     and pa.amount_krw = 10000
     and pa.payment_key = 'synthetic-trigger-column-key'
     and pa.updated_at = timestamptz '2026-01-15 00:00:00+00'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
where pa.order_id = 'synthetic-attempt-trigger';

update public.payment_attempts
set provider_response = jsonb_build_object(
  'receiptUrl', 'https://example.test/receipt/trigger-update',
  'orderId', 'synthetic-attempt-trigger',
  'totalAmount', 10000,
  'initial_reconciliation', jsonb_build_object('result', 'payment_found')
)
where order_id = 'synthetic-attempt-trigger';

insert into attempt_redaction_results (test_name, status, detail)
select
  'update of provider_response is masked without changing status or amount',
  case
    when pa.provider_response ->> 'receiptUrl' = '[REDACTED]'
     and pa.provider_response ->> 'orderId' = 'synthetic-attempt-trigger'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response #>> '{initial_reconciliation,result}' = 'payment_found'
     and pa.provider_response::text not like '%example.test/receipt/trigger-update%'
     and pa.status = 'initiated'
     and pa.amount_krw = 10000
     and pa.payment_key = 'synthetic-trigger-column-key'
     and pa.updated_at is distinct from timestamptz '2026-01-15 00:00:00+00'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
where pa.order_id = 'synthetic-attempt-trigger';

insert into attempt_redaction_results (test_name, status, detail)
select
  'apply function uses the existing helper and stores no backup',
  case
    when position('redact_sensitive_payload' in def) > 0
     and position('paymentkey' in lower(def)) = 0
     and position('billing_credentials' in def) = 0
     and position('billing_key' in def) = 0
     and position('create table' in lower(def)) = 0
     and position('backup' in lower(def)) = 0
     and position('payment_attempts' in def) > 0
     and position('provider_response' in def) > 0
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from (
  select pg_get_functiondef(
    'private.apply_payment_attempt_provider_response_redaction()'::regprocedure
  ) as def
) fn;

do $$
declare
  v_role text;
begin
  foreach v_role in array array['authenticated', 'service_role']
  loop
    begin
      execute format('set local role %I', v_role);
      perform private.apply_payment_attempt_provider_response_redaction();
      execute 'reset role';
      insert into attempt_redaction_results (test_name, status, detail)
      values (v_role || ' cannot execute provider response redaction', 'FAIL', 'call returned');
    exception
      when insufficient_privilege then
        execute 'reset role';
        insert into attempt_redaction_results (test_name, status, detail)
        values (
          v_role || ' cannot execute provider response redaction',
          'PASS',
          'permission denied'
        );
      when others then
        execute 'reset role';
        insert into attempt_redaction_results (test_name, status, detail)
        values (
          v_role || ' cannot execute provider response redaction',
          'FAIL',
          sqlstate
        );
    end;
  end loop;
end
$$;

\ir p1_22_payment_attempt_provider_response_redaction_rollback.sql

insert into attempt_redaction_results (test_name, status, detail)
select
  'rollback drops only the apply function',
  case
    when to_regprocedure('private.apply_payment_attempt_provider_response_redaction()') is null
     and to_regprocedure('private.redact_sensitive_payload(jsonb)') is not null
     and to_regprocedure('private.redact_payment_row()') is not null
     and position('BEFORE INSERT OR UPDATE OF provider_response' in trigger_def) > 0
    then 'PASS'
    else 'FAIL'
  end,
  coalesce(trigger_def, 'missing trigger')
from (
  select pg_get_triggerdef(t.oid) as trigger_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where t.tgname = 'payment_attempts_redact_payload'
    and n.nspname = 'public'
    and c.relname = 'payment_attempts'
    and not t.tgisinternal
) existing;

insert into public.payment_attempts (
  gym_id,
  user_id,
  provider,
  payment_type,
  billing_interval,
  amount_krw,
  currency,
  order_id,
  payment_key,
  status,
  activation_status,
  recovery_status,
  provider_response
)
select
  p.gym_id,
  p.id,
  'toss',
  'legacy_checkout',
  'monthly',
  10000,
  'KRW',
  'synthetic-attempt-after-rollback',
  'synthetic-after-rollback-column-key',
  'initiated',
  'not_started',
  'none',
  jsonb_build_object(
    'paymentKey', 'synthetic-after-rollback-pay',
    'orderId', 'synthetic-attempt-after-rollback',
    'totalAmount', 10000
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d301';

insert into attempt_redaction_results (test_name, status, detail)
select
  'trigger still masks new rows after rollback',
  case
    when pa.provider_response ->> 'paymentKey' = '[REDACTED]'
     and pa.provider_response ->> 'orderId' = 'synthetic-attempt-after-rollback'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response::text not like '%synthetic-after-rollback-pay%'
     and pa.status = 'initiated'
     and pa.amount_krw = 10000
     and pa.payment_key = 'synthetic-after-rollback-column-key'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.payment_attempts pa
where pa.order_id = 'synthetic-attempt-after-rollback';

select test_name, status, detail
from attempt_redaction_results
order by test_name;

rollback;
