-- Synthetic cleanup checks. This script rolls back.
-- The bounds below are the fixture counts, not an audited production count.
-- Rows inserted with the payload trigger disabled are the rows cleanup must mask.
-- Rows inserted with that trigger enabled are masked on insert and must stay unchanged.
-- The pending checkout and payment-attempt fixtures disable the trigger so the
-- unchanged-row checks still cover a stored raw payload.

begin;

create temp table cleanup_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000d101', 'cleanup-fixture@example.test');

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set
  name = 'Synthetic Cleanup Gym',
  plan_code = 'pro',
  member_limit = -1,
  subscription_status = 'active',
  current_period_end = timestamptz '2026-02-15 00:00:00+00',
  billing_provider = 'toss',
  billing_customer_id = 'synthetic-customer',
  billing_subscription_id = 'synthetic-billing-key-value',
  auto_renew = true
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d101'
  and g.id = p.gym_id;

insert into private.billing_credentials (gym_id, provider, billing_key)
select p.gym_id, 'toss', 'synthetic-billing-key-value'
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d101';

-- Cleanup does not write payment attempts. Insert this row with redaction off
-- so the unchanged-row check still sees a stored raw provider response.
alter table public.payment_attempts disable trigger payment_attempts_redact_payload;

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
  provider_response
)
select
  p.gym_id,
  p.id,
  'toss',
  'initial_billing',
  'monthly',
  10000,
  'KRW',
  'synthetic-attempt-order',
  'synthetic-attempt-payment-key',
  'synthetic-customer',
  'synthetic-legacy-billing-ref',
  'completed',
  'succeeded',
  'none',
  jsonb_build_object(
    'paymentKey', 'synthetic-attempt-payment-key',
    'orderId', 'synthetic-attempt-order',
    'totalAmount', 10000,
    'initial_reconciliation', jsonb_build_object('result', 'payment_found')
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d101';

alter table public.payment_attempts enable trigger payment_attempts_redact_payload;

alter table public.checkout_sessions disable trigger checkout_sessions_redact_payload;
alter table public.subscriptions disable trigger subscriptions_redact_payload;

insert into public.checkout_sessions (
  gym_id, user_id, provider, "interval", amount_krw, amount_usd_cents, currency,
  status, order_id, provider_session_id, success_url, fail_url, raw,
  created_at, completed_at
)
select
  p.gym_id,
  p.id,
  'toss',
  'monthly',
  fixture.amount_krw,
  0,
  'KRW',
  fixture.status,
  fixture.order_id,
  fixture.provider_session_id,
  'https://example.test/success-return',
  'https://example.test/fail-return',
  fixture.raw,
  timestamptz '2026-01-15 00:00:00+00',
  fixture.completed_at
from public.profiles p
cross join (
  values
    (
      'completed',
      'synthetic-order-pre-a',
      'synthetic-session-pre-a',
      10000,
      timestamptz '2026-01-15 00:05:00+00',
      jsonb_build_object(
        'paymentKey', 'synthetic-pay-completed',
        'lastTransactionKey', 'synthetic-txn-key',
        'orderId', 'synthetic-order-pre-a',
        'status', 'DONE',
        'totalAmount', 10000,
        'approvedAt', '2026-01-15T00:00:00Z',
        'method', 'card',
        'mId', 'synthetic-mid-value',
        'approveNo', 'synthetic-approval',
        'secret', 'synthetic-secret-value',
        'card', jsonb_build_object(
          'number', '4111111111111111',
          'approveNo', 'synthetic-approval-card'
        ),
        'receipt', jsonb_build_object('url', 'https://example.test/receipt/synthetic'),
        'checkout', jsonb_build_object('url', 'https://example.test/checkout/synthetic'),
        'orderName', 'synthetic order',
        'successUrl', 'https://example.test/success-return'
      )
    ),
    (
      'completed',
      'synthetic-order-pre-b',
      'synthetic-session-pre-b',
      10000,
      timestamptz '2026-01-15 00:06:00+00',
      jsonb_build_object(
        'payment_key', 'synthetic-pay-snake',
        'last_transaction_key', 'synthetic-txn-snake',
        'approval_number', 'synthetic-approval-snake',
        'receipt_url', 'https://example.test/receipt/snake',
        'checkout_url', 'https://example.test/checkout/snake',
        'merchant_id', 'synthetic-merchant-value',
        'customer_email', 'member@example.test',
        'order_id', 'synthetic-order-pre-b',
        'total_amount', 10000,
        'approved_at', '2026-01-15T00:00:00Z'
      )
    ),
    (
      'completed',
      'synthetic-order-pan',
      'synthetic-session-pan',
      10000,
      timestamptz '2026-01-15 00:07:00+00',
      jsonb_build_object(
        'orderId', 'synthetic-order-pan',
        'totalAmount', 10000,
        'note', '4111111111111111'
      )
    )
) as fixture(status, order_id, provider_session_id, amount_krw, completed_at, raw)
where p.id = '00000000-0000-0000-0000-00000000d101';

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw,
  started_at, ends_at, created_at, raw
)
select
  p.gym_id,
  'pro',
  fixture.status,
  'toss',
  fixture.provider_ref,
  fixture.amount_krw,
  timestamptz '2026-01-15 00:00:00+00',
  timestamptz '2026-02-15 00:00:00+00',
  timestamptz '2026-01-15 00:00:00+00',
  fixture.raw
from public.profiles p
cross join (
  values
    (
      'active',
      'synthetic-provider-ref-unredacted',
      10000,
      jsonb_build_object(
        'paymentKey', 'synthetic-pay-sub',
        'secret', 'synthetic-secret-sub',
        'card', jsonb_build_object('number', '4111111111111111'),
        'customerEmail', 'member@example.test',
        'orderId', 'synthetic-order-sub-unredacted',
        'totalAmount', 10000,
        'status', 'DONE'
      )
    ),
    (
      'active',
      'synthetic-provider-ref-nested',
      10000,
      jsonb_build_object(
        'orderId', 'synthetic-order-sub-nested',
        'totalAmount', 10000,
        'status', 'DONE',
        'approvedAt', '2026-01-15T00:00:00Z',
        'provider_response', jsonb_build_object(
          'payment', jsonb_build_object(
            'paymentKey', 'synthetic-pay-nested',
            'lastTransactionKey', 'synthetic-txn-nested',
            'mId', 'synthetic-mid-nested',
            'approveNo', 'synthetic-approval-nested',
            'receipt', jsonb_build_object('url', 'https://example.test/receipt/nested'),
            'checkout', jsonb_build_object('url', 'https://example.test/checkout/nested'),
            'orderId', 'synthetic-order-sub-nested',
            'totalAmount', 10000
          )
        )
      )
    )
) as fixture(status, provider_ref, amount_krw, raw)
where p.id = '00000000-0000-0000-0000-00000000d101';

-- These inserts keep the redaction trigger enabled. Payment, merchant, and
-- receipt fields are masked on insert, so those rows are not cleanup targets.
alter table public.checkout_sessions enable trigger checkout_sessions_redact_payload;
alter table public.subscriptions enable trigger subscriptions_redact_payload;

insert into public.checkout_sessions (
  gym_id, user_id, provider, "interval", amount_krw, amount_usd_cents, currency,
  status, order_id, provider_session_id, success_url, fail_url, raw,
  created_at, completed_at
)
select
  p.gym_id,
  p.id,
  'toss',
  'monthly',
  fixture.amount_krw,
  0,
  'KRW',
  fixture.status,
  fixture.order_id,
  fixture.provider_session_id,
  'https://example.test/success-return',
  'https://example.test/fail-return',
  fixture.raw,
  timestamptz '2026-01-15 00:00:00+00',
  fixture.completed_at
from public.profiles p
cross join (
  values
    (
      'completed',
      'synthetic-order-post',
      'synthetic-session-post',
      10000,
      timestamptz '2026-01-15 00:08:00+00',
      jsonb_build_object(
        'paymentKey', 'synthetic-pay-post',
        'lastTransactionKey', 'synthetic-txn-post',
        'secret', 'synthetic-secret-post',
        'orderId', 'synthetic-order-post',
        'totalAmount', 10000,
        'status', 'DONE',
        'mId', 'synthetic-mid-post',
        'receipt', jsonb_build_object('url', 'https://example.test/receipt/post')
      )
    ),
    (
      'completed',
      'synthetic-order-clean',
      'synthetic-session-clean',
      9000,
      timestamptz '2026-01-15 00:09:00+00',
      jsonb_build_object(
        'orderId', 'synthetic-order-clean',
        'totalAmount', 9000,
        'status', 'DONE',
        'approvedAt', '2026-01-15T00:00:00Z',
        'method', 'card'
      )
    ),
    (
      'pending',
      'synthetic-order-pending',
      null,
      10000,
      null,
      jsonb_build_object(
        'orderId', 'synthetic-order-pending',
        'totalAmount', 10000
      )
    ),
    (
      'failed',
      'synthetic-order-failed',
      null,
      10000,
      null,
      jsonb_build_object(
        'error', 'synthetic failure',
        'orderId', 'synthetic-order-failed'
      )
    )
) as fixture(status, order_id, provider_session_id, amount_krw, completed_at, raw)
where p.id = '00000000-0000-0000-0000-00000000d101';

-- Cleanup rewrites completed checkout rows only. Insert this pending row with
-- redaction off so the unchanged-row check still sees a stored raw payload.
alter table public.checkout_sessions disable trigger checkout_sessions_redact_payload;

insert into public.checkout_sessions (
  gym_id, user_id, provider, "interval", amount_krw, amount_usd_cents, currency,
  status, order_id, provider_session_id, success_url, fail_url, raw,
  created_at, completed_at
)
select
  p.gym_id,
  p.id,
  'toss',
  'monthly',
  10000,
  0,
  'KRW',
  'pending',
  'synthetic-order-pending-key',
  null,
  'https://example.test/success-return',
  'https://example.test/fail-return',
  jsonb_build_object(
    'paymentKey', 'synthetic-pay-pending',
    'orderId', 'synthetic-order-pending-key',
    'totalAmount', 10000
  ),
  timestamptz '2026-01-15 00:00:00+00',
  null
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d101';

alter table public.checkout_sessions enable trigger checkout_sessions_redact_payload;

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw,
  started_at, ends_at, created_at, raw
)
select
  p.gym_id,
  'pro',
  fixture.status,
  'toss',
  fixture.provider_ref,
  fixture.amount_krw,
  timestamptz '2026-01-15 00:00:00+00',
  timestamptz '2026-02-15 00:00:00+00',
  timestamptz '2026-01-15 00:00:00+00',
  fixture.raw
from public.profiles p
cross join (
  values
    (
      'active',
      'synthetic-provider-ref-key',
      8000,
      jsonb_build_object(
        'payment_key', 'synthetic-pay-sub-key',
        'orderId', 'synthetic-order-sub-key',
        'totalAmount', 8000,
        'status', 'active'
      )
    ),
    (
      'canceled',
      null,
      0,
      jsonb_build_object(
        'orderId', 'synthetic-order-sub-clean',
        'totalAmount', 0,
        'status', 'canceled'
      )
    )
) as fixture(status, provider_ref, amount_krw, raw)
where p.id = '00000000-0000-0000-0000-00000000d101';

create temp table checkout_before on commit drop as
select
  id,
  gym_id,
  user_id,
  provider,
  "interval",
  amount_krw,
  amount_usd_cents,
  currency,
  status,
  order_id,
  provider_session_id,
  success_url,
  fail_url,
  created_at,
  completed_at,
  raw,
  raw::text as raw_text,
  cmin::text as cmin_text
from public.checkout_sessions;

create temp table subscription_before on commit drop as
select
  id,
  gym_id,
  plan_code,
  status,
  provider,
  provider_ref,
  amount_krw,
  started_at,
  ends_at,
  created_at,
  raw,
  raw::text as raw_text,
  cmin::text as cmin_text
from public.subscriptions;

create temp table protected_before on commit drop as
select
  g.billing_subscription_id,
  g.auto_renew,
  g.plan_code,
  g.subscription_status,
  g.current_period_end,
  g.cmin::text as gym_cmin,
  c.billing_key,
  c.created_at as credential_created_at,
  c.updated_at as credential_updated_at,
  c.cmin::text as credential_cmin,
  pa.billing_key_ref,
  pa.payment_key,
  pa.provider_response,
  pa.provider_response::text as provider_response_text,
  pa.status as attempt_status,
  pa.amount_krw as attempt_amount,
  pa.updated_at as attempt_updated_at,
  pa.cmin::text as attempt_cmin
from public.profiles p
join public.gyms g on g.id = p.gym_id
join private.billing_credentials c on c.gym_id = p.gym_id
join public.payment_attempts pa on pa.order_id = 'synthetic-attempt-order'
where p.id = '00000000-0000-0000-0000-00000000d101';

create temp table privilege_before on commit drop as
select coalesce(string_agg(line, E'\n' order by line), '') as snapshot
from (
  select n.nspname || '.' || c.relname || ' relacl=' || coalesce(c.relacl::text, '') as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private')
    and c.relname in (
      'members',
      'gyms',
      'checkout_sessions',
      'subscriptions',
      'payment_attempts',
      'billing_credentials'
    )
  union all
  select n.nspname || '.' || c.relname || '.' || a.attname || ' attacl=' || coalesce(a.attacl::text, '')
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private')
    and c.relname in (
      'members',
      'gyms',
      'checkout_sessions',
      'subscriptions',
      'payment_attempts',
      'billing_credentials'
    )
    and a.attnum > 0
    and not a.attisdropped
) grants;

create temp table verification_before on commit drop as
select metric, row_count
from private.sensitive_raw_cleanup_verification();

do $$
begin
  begin
    perform private.apply_sensitive_raw_cleanup(null, null, null, null);
    insert into cleanup_results (test_name, status, detail)
    values ('unset bounds abort', 'FAIL', 'call returned');
  exception
    when others then
      if sqlerrm = 'SENSITIVE_RAW_CLEANUP_ABORTED bounds are missing or inverted' then
        insert into cleanup_results (test_name, status, detail)
        values ('unset bounds abort', 'PASS', 'aborted');
      else
        insert into cleanup_results (test_name, status, detail)
        values ('unset bounds abort', 'FAIL', sqlstate);
      end if;
  end;
end
$$;

do $$
begin
  begin
    perform private.apply_sensitive_raw_cleanup(4, 4, 99, 99);
    insert into cleanup_results (test_name, status, detail)
    values ('unexpected counts abort before any rewrite', 'FAIL', 'call returned');
  exception
    when others then
      if sqlerrm like 'SENSITIVE_RAW_CLEANUP_ABORTED completed_checkout=%' then
        insert into cleanup_results (test_name, status, detail)
        values ('unexpected counts abort before any rewrite', 'PASS', 'aborted');
      else
        insert into cleanup_results (test_name, status, detail)
        values ('unexpected counts abort before any rewrite', 'FAIL', sqlstate);
      end if;
  end;
end
$$;

insert into cleanup_results (test_name, status, detail)
select
  'aborted cleanup leaves raw and protected rows unchanged',
  case
    when not exists (
      select 1
      from checkout_before b
      join public.checkout_sessions c on c.id = b.id
      where c.raw::text is distinct from b.raw_text
         or c.cmin::text is distinct from b.cmin_text
    )
     and not exists (
      select 1
      from subscription_before b
      join public.subscriptions s on s.id = b.id
      where s.raw::text is distinct from b.raw_text
         or s.cmin::text is distinct from b.cmin_text
    )
     and exists (
      select 1
      from protected_before b
      join public.profiles p on p.id = '00000000-0000-0000-0000-00000000d101'
      join public.gyms g on g.id = p.gym_id
      join private.billing_credentials c on c.gym_id = p.gym_id
      join public.payment_attempts pa on pa.order_id = 'synthetic-attempt-order'
      where g.billing_subscription_id = b.billing_subscription_id
        and g.cmin::text = b.gym_cmin
        and c.billing_key = b.billing_key
        and convert_to(c.billing_key, 'UTF8') = convert_to(b.billing_key, 'UTF8')
        and c.cmin::text = b.credential_cmin
        and pa.billing_key_ref = b.billing_key_ref
        and convert_to(pa.billing_key_ref, 'UTF8') = convert_to(b.billing_key_ref, 'UTF8')
        and pa.payment_key = b.payment_key
        and pa.provider_response::text = b.provider_response_text
        and pa.cmin::text = b.attempt_cmin
    )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

do $$
declare
  v_checkout integer;
  v_subscription integer;
begin
  select completed_checkout_updated, subscriptions_updated
  into v_checkout, v_subscription
  from private.apply_sensitive_raw_cleanup(3, 3, 2, 2);

  insert into cleanup_results (test_name, status, detail)
  values (
    'cleanup updates the counted target rows',
    case
      when v_checkout = 3 and v_subscription = 2 then 'PASS'
      else 'FAIL'
    end,
    'checkout=' || coalesce(v_checkout::text, 'null')
      || ' subscription=' || coalesce(v_subscription::text, 'null')
  );
end
$$;

insert into cleanup_results (test_name, status, detail)
select
  'completed checkout raw drops sensitive values and keeps payment facts',
  case
    when pre_a.raw ->> 'paymentKey' = '[REDACTED]'
     and pre_a.raw ->> 'lastTransactionKey' = '[REDACTED]'
     and pre_a.raw ->> 'mId' = '[REDACTED]'
     and pre_a.raw ->> 'approveNo' = '[REDACTED]'
     and pre_a.raw ->> 'secret' = '[REDACTED]'
     and pre_a.raw ->> 'card' = '[REDACTED]'
     and pre_a.raw ->> 'receipt' = '[REDACTED]'
     and pre_a.raw ->> 'checkout' = '[REDACTED]'
     and pre_a.raw ->> 'orderId' = 'synthetic-order-pre-a'
     and pre_a.raw ->> 'status' = 'DONE'
     and pre_a.raw ->> 'totalAmount' = '10000'
     and pre_a.raw ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and pre_a.raw ->> 'method' = 'card'
     and pre_a.raw ->> 'orderName' = 'synthetic order'
     and pre_a.raw ->> 'successUrl' = 'https://example.test/success-return'
     and pre_a.raw::text not like '%synthetic-pay-completed%'
     and pre_a.raw::text not like '%synthetic-txn-key%'
     and pre_a.raw::text not like '%synthetic-mid-value%'
     and pre_a.raw::text not like '%synthetic-approval%'
     and pre_a.raw::text not like '%synthetic-secret-value%'
     and pre_a.raw::text not like '%4111111111111111%'
     and pre_a.raw::text not like '%example.test/receipt%'
     and pre_a.raw::text not like '%example.test/checkout%'
     and pre_b.raw ->> 'payment_key' = '[REDACTED]'
     and pre_b.raw ->> 'last_transaction_key' = '[REDACTED]'
     and pre_b.raw ->> 'approval_number' = '[REDACTED]'
     and pre_b.raw ->> 'receipt_url' = '[REDACTED]'
     and pre_b.raw ->> 'checkout_url' = '[REDACTED]'
     and pre_b.raw ->> 'merchant_id' = '[REDACTED]'
     and pre_b.raw ->> 'customer_email' = '[REDACTED]'
     and pre_b.raw ->> 'order_id' = 'synthetic-order-pre-b'
     and pre_b.raw ->> 'total_amount' = '10000'
     and pre_b.raw ->> 'approved_at' = '2026-01-15T00:00:00Z'
     and pre_b.raw::text not like '%synthetic-pay-snake%'
     and pre_b.raw::text not like '%member@example.test%'
     and pan.raw ->> 'note' = '[REDACTED]'
     and pan.raw ->> 'orderId' = 'synthetic-order-pan'
     and pan.raw ->> 'totalAmount' = '10000'
     and pan.raw::text not like '%4111111111111111%'
     and post.raw ->> 'paymentKey' = '[REDACTED]'
     and post.raw ->> 'lastTransactionKey' = '[REDACTED]'
     and post.raw ->> 'mId' = '[REDACTED]'
     and post.raw ->> 'receipt' = '[REDACTED]'
     and post.raw ->> 'secret' = '[REDACTED]'
     and post.raw ->> 'orderId' = 'synthetic-order-post'
     and post.raw ->> 'totalAmount' = '10000'
     and post.raw::text not like '%synthetic-pay-post%'
     and post.raw::text not like '%example.test/receipt/post%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.checkout_sessions pre_a
join public.checkout_sessions pre_b on pre_b.order_id = 'synthetic-order-pre-b'
join public.checkout_sessions pan on pan.order_id = 'synthetic-order-pan'
join public.checkout_sessions post on post.order_id = 'synthetic-order-post'
where pre_a.order_id = 'synthetic-order-pre-a';

insert into cleanup_results (test_name, status, detail)
select
  'subscription raw drops nested sensitive values and keeps payment facts',
  case
    when plain.raw ->> 'paymentKey' = '[REDACTED]'
     and plain.raw ->> 'secret' = '[REDACTED]'
     and plain.raw ->> 'card' = '[REDACTED]'
     and plain.raw ->> 'customerEmail' = '[REDACTED]'
     and plain.raw ->> 'orderId' = 'synthetic-order-sub-unredacted'
     and plain.raw ->> 'totalAmount' = '10000'
     and plain.raw ->> 'status' = 'DONE'
     and plain.raw::text not like '%synthetic-pay-sub%'
     and plain.raw::text not like '%synthetic-secret-sub%'
     and plain.raw::text not like '%member@example.test%'
     and keyed.raw ->> 'payment_key' = '[REDACTED]'
     and keyed.raw ->> 'orderId' = 'synthetic-order-sub-key'
     and keyed.raw ->> 'totalAmount' = '8000'
     and keyed.raw::text not like '%synthetic-pay-sub-key%'
     and nested.raw ->> 'orderId' = 'synthetic-order-sub-nested'
     and nested.raw ->> 'totalAmount' = '10000'
     and nested.raw ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and nested.raw #>> '{provider_response,payment,paymentKey}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,lastTransactionKey}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,mId}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,approveNo}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,receipt}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,checkout}' = '[REDACTED]'
     and nested.raw #>> '{provider_response,payment,orderId}' = 'synthetic-order-sub-nested'
     and nested.raw #>> '{provider_response,payment,totalAmount}' = '10000'
     and nested.raw::text not like '%synthetic-pay-nested%'
     and nested.raw::text not like '%synthetic-txn-nested%'
     and nested.raw::text not like '%example.test/receipt/nested%'
     and nested.raw::text not like '%example.test/checkout/nested%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.subscriptions plain
join public.subscriptions keyed on keyed.provider_ref = 'synthetic-provider-ref-key'
join public.subscriptions nested on nested.provider_ref = 'synthetic-provider-ref-nested'
where plain.provider_ref = 'synthetic-provider-ref-unredacted';

insert into cleanup_results (test_name, status, detail)
select
  'non-target raw and reference columns stay unchanged',
  case
    when not exists (
      select 1
      from checkout_before b
      join public.checkout_sessions c on c.id = b.id
      where b.status is distinct from c.status
         or b.amount_krw is distinct from c.amount_krw
         or b.amount_usd_cents is distinct from c.amount_usd_cents
         or b.currency is distinct from c.currency
         or b.order_id is distinct from c.order_id
         or b.provider_session_id is distinct from c.provider_session_id
         or b.success_url is distinct from c.success_url
         or b.fail_url is distinct from c.fail_url
         or b.created_at is distinct from c.created_at
         or b.completed_at is distinct from c.completed_at
         or b.provider is distinct from c.provider
         or b."interval" is distinct from c."interval"
         or b.gym_id is distinct from c.gym_id
         or b.user_id is distinct from c.user_id
         or (
           b.order_id in (
             'synthetic-order-clean',
             'synthetic-order-pending',
             'synthetic-order-pending-key',
             'synthetic-order-failed',
             'synthetic-order-post'
           )
           and (
             c.raw::text is distinct from b.raw_text
             or c.cmin::text is distinct from b.cmin_text
           )
         )
         or (
           b.order_id not in (
             'synthetic-order-clean',
             'synthetic-order-pending',
             'synthetic-order-pending-key',
             'synthetic-order-failed',
             'synthetic-order-post'
           )
           and c.cmin::text is not distinct from b.cmin_text
         )
    )
     and not exists (
      select 1
      from subscription_before b
      join public.subscriptions s on s.id = b.id
      where b.status is distinct from s.status
         or b.amount_krw is distinct from s.amount_krw
         or b.provider_ref is distinct from s.provider_ref
         or b.plan_code is distinct from s.plan_code
         or b.provider is distinct from s.provider
         or b.started_at is distinct from s.started_at
         or b.ends_at is distinct from s.ends_at
         or b.created_at is distinct from s.created_at
         or (
           (
             b.provider_ref is null
             or b.provider_ref = 'synthetic-provider-ref-key'
           )
           and (
             s.raw::text is distinct from b.raw_text
             or s.cmin::text is distinct from b.cmin_text
           )
         )
         or (
           b.provider_ref is not null
           and b.provider_ref is distinct from 'synthetic-provider-ref-key'
           and s.cmin::text is not distinct from b.cmin_text
         )
    )
     and exists (
      select 1
      from public.checkout_sessions
      where order_id = 'synthetic-order-pending-key'
        and raw ->> 'paymentKey' = 'synthetic-pay-pending'
    )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into cleanup_results (test_name, status, detail)
select
  'billing credential and legacy billing reference stay byte-identical',
  case
    when g.billing_subscription_id = b.billing_subscription_id
     and convert_to(g.billing_subscription_id, 'UTF8') = convert_to(b.billing_subscription_id, 'UTF8')
     and g.auto_renew = b.auto_renew
     and g.plan_code = b.plan_code
     and g.subscription_status = b.subscription_status
     and g.current_period_end = b.current_period_end
     and g.cmin::text = b.gym_cmin
     and c.billing_key = b.billing_key
     and convert_to(c.billing_key, 'UTF8') = convert_to(b.billing_key, 'UTF8')
     and c.created_at = b.credential_created_at
     and c.updated_at = b.credential_updated_at
     and c.cmin::text = b.credential_cmin
     and pa.billing_key_ref = b.billing_key_ref
     and convert_to(pa.billing_key_ref, 'UTF8') = convert_to(b.billing_key_ref, 'UTF8')
     and pa.payment_key = b.payment_key
     and pa.provider_response::text = b.provider_response_text
     and pa.status = b.attempt_status
     and pa.amount_krw = b.attempt_amount
     and pa.updated_at = b.attempt_updated_at
     and pa.cmin::text = b.attempt_cmin
     and pa.provider_response ->> 'paymentKey' = 'synthetic-attempt-payment-key'
     and pa.provider_response #>> '{initial_reconciliation,result}' = 'payment_found'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from protected_before b
join public.profiles p on p.id = '00000000-0000-0000-0000-00000000d101'
join public.gyms g on g.id = p.gym_id
join private.billing_credentials c on c.gym_id = p.gym_id
join public.payment_attempts pa on pa.order_id = 'synthetic-attempt-order';

insert into cleanup_results (test_name, status, detail)
select
  'member and payment select grants stay unchanged',
  case
    when privilege_before.snapshot = (
      select coalesce(string_agg(line, E'\n' order by line), '')
      from (
        select n.nspname || '.' || c.relname || ' relacl=' || coalesce(c.relacl::text, '') as line
        from pg_class c
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('public', 'private')
          and c.relname in (
            'members',
            'gyms',
            'checkout_sessions',
            'subscriptions',
            'payment_attempts',
            'billing_credentials'
          )
        union all
        select n.nspname || '.' || c.relname || '.' || a.attname || ' attacl=' || coalesce(a.attacl::text, '')
        from pg_attribute a
        join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('public', 'private')
          and c.relname in (
            'members',
            'gyms',
            'checkout_sessions',
            'subscriptions',
            'payment_attempts',
            'billing_credentials'
          )
          and a.attnum > 0
          and not a.attisdropped
      ) grants
    )
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from privilege_before;

insert into cleanup_results (test_name, status, detail)
select
  'link counts and status counts stay unchanged',
  case
    when not exists (
      select 1
      from verification_before b
      join private.sensitive_raw_cleanup_verification() a using (metric)
      where b.metric not in (
        'completed_checkout_rows_redaction_would_change',
        'completed_checkout_unredacted_sensitive_keys',
        'subscription_rows_redaction_would_change',
        'subscription_unredacted_sensitive_keys'
      )
        and b.row_count is distinct from a.row_count
    )
     and (
      select row_count
      from verification_before
      where metric = 'completed_checkout_rows_redaction_would_change'
     ) = 3
     and (
      select row_count
      from verification_before
      where metric = 'subscription_rows_redaction_would_change'
     ) = 2
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

create temp table cleaned_raw on commit drop as
select order_id, raw::text as raw_text
from public.checkout_sessions
where order_id = 'synthetic-order-pre-a';

do $$
declare
  v_checkout integer;
  v_subscription integer;
begin
  select completed_checkout_updated, subscriptions_updated
  into v_checkout, v_subscription
  from private.apply_sensitive_raw_cleanup(3, 3, 2, 2);

  insert into cleanup_results (test_name, status, detail)
  values (
    'second cleanup changes 0 rows',
    case
      when v_checkout = 0 and v_subscription = 0 then 'PASS'
      else 'FAIL'
    end,
    'checkout=' || coalesce(v_checkout::text, 'null')
      || ' subscription=' || coalesce(v_subscription::text, 'null')
  );
end
$$;

insert into cleanup_results (test_name, status, detail)
select
  'reapplying the mask still changes 0 rows',
  case
    when saved.raw_text = live.raw::text
     and (
      select row_count
      from private.sensitive_raw_cleanup_verification()
      where metric = 'completed_checkout_rows_redaction_would_change'
     ) = 0
     and (
      select row_count
      from private.sensitive_raw_cleanup_verification()
      where metric = 'subscription_rows_redaction_would_change'
     ) = 0
     and (
      select row_count
      from private.sensitive_raw_cleanup_verification()
      where metric = 'completed_checkout_unredacted_sensitive_keys'
     ) = 0
     and (
      select row_count
      from private.sensitive_raw_cleanup_verification()
      where metric = 'subscription_unredacted_sensitive_keys'
     ) = 0
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from cleaned_raw saved
join public.checkout_sessions live on live.order_id = saved.order_id;

insert into cleanup_results (test_name, status, detail)
select
  'cleanup function does not name protected billing storage',
  case
    when position('billing_credentials' in def) = 0
     and position('billing_key' in def) = 0
     and position('payment_attempts' in def) = 0
     and position('billing_subscription_id' in def) = 0
     and position('allow_billing_update' in def) = 0
     and position('grant ' in lower(def)) = 0
     and position('revoke ' in lower(def)) = 0
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from (
  select pg_get_functiondef(
    'private.apply_sensitive_raw_cleanup(integer,integer,integer,integer)'::regprocedure
  ) as def
) fn;

do $$
begin
  begin
    execute 'set local role authenticated';
    perform private.apply_sensitive_raw_cleanup(0, 0, 0, 0);
    execute 'reset role';
    insert into cleanup_results (test_name, status, detail)
    values ('authenticated cannot execute the cleanup', 'FAIL', 'call returned');
  exception
    when insufficient_privilege then
      execute 'reset role';
      insert into cleanup_results (test_name, status, detail)
      values ('authenticated cannot execute the cleanup', 'PASS', 'permission denied');
    when others then
      execute 'reset role';
      insert into cleanup_results (test_name, status, detail)
      values ('authenticated cannot execute the cleanup', 'FAIL', sqlstate);
  end;
end
$$;

select test_name, status, detail
from cleanup_results
order by test_name;

rollback;
