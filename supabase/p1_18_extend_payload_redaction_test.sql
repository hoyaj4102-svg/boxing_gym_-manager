-- Checks that new stored-payload keys are masked on insert and update.
-- Synthetic values only. This script rolls back.

begin;

create temp table redaction_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000d201', 'redaction-fixture@example.test');

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set
  name = 'Synthetic Redaction Gym',
  plan_code = 'pro',
  member_limit = -1,
  subscription_status = 'active',
  current_period_end = timestamptz '2026-02-15 00:00:00+00',
  billing_provider = 'toss',
  billing_customer_id = 'synthetic-customer',
  billing_subscription_id = 'synthetic-billing-key-value',
  auto_renew = true
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d201'
  and g.id = p.gym_id;

insert into private.billing_credentials (gym_id, provider, billing_key)
select p.gym_id, 'toss', 'synthetic-billing-key-value'
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d201';

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
  'auto_renewal',
  'monthly',
  10000,
  'KRW',
  'synthetic-redaction-order',
  'synthetic-attempt-payment-key',
  'synthetic-customer',
  'synthetic-legacy-billing-ref',
  'activation_pending',
  'pending',
  'none',
  jsonb_build_object(
    'paymentKey', 'synthetic-pay-attempt',
    'lastTransactionKey', 'synthetic-txn-attempt',
    'mId', 'synthetic-mid-attempt',
    'approveNo', 'synthetic-approval-attempt',
    'receipt', jsonb_build_object('url', 'https://example.test/receipt/attempt'),
    'checkout', jsonb_build_object('url', 'https://example.test/checkout/attempt'),
    'orderId', 'synthetic-redaction-order',
    'status', 'DONE',
    'totalAmount', 10000,
    'approvedAt', '2026-01-15T00:00:00Z',
    'method', 'card',
    'initial_reconciliation', jsonb_build_object(
      'result', 'payment_found',
      'order_id', 'synthetic-redaction-order'
    ),
    'reconciliation', jsonb_build_object('status', 'claimed')
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d201';

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
  'synthetic-redaction-checkout',
  'synthetic-attempt-payment-key',
  jsonb_build_object(
    'paymentKey', 'synthetic-pay-checkout',
    'payment_key', 'synthetic-pay-checkout-snake',
    'lastTransactionKey', 'synthetic-txn-checkout',
    'transactionKey', 'synthetic-txn-checkout-alt',
    'mId', 'synthetic-mid-checkout',
    'merchant_id', 'synthetic-merchant-checkout',
    'approveNo', 'synthetic-approval-checkout',
    'approval_number', 'synthetic-approval-number',
    'receipt', jsonb_build_object('url', 'https://example.test/receipt/checkout'),
    'checkout_url', 'https://example.test/checkout/flat',
    'secret', 'synthetic-secret-checkout',
    'orderId', 'synthetic-redaction-checkout',
    'status', 'DONE',
    'totalAmount', 10000,
    'approvedAt', '2026-01-15T00:00:00Z',
    'method', 'card',
    'successUrl', 'https://example.test/success-return'
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d201';

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw, raw
)
select
  p.gym_id,
  'pro',
  'active',
  'toss',
  'synthetic-attempt-payment-key',
  10000,
  jsonb_build_object(
    'payment_key', 'synthetic-pay-subscription',
    'orderId', 'synthetic-redaction-subscription',
    'totalAmount', 10000,
    'status', 'DONE',
    'provider_response', jsonb_build_object(
      'payment', jsonb_build_object(
        'last_transaction_key', 'synthetic-txn-subscription',
        'receipt_url', 'https://example.test/receipt/subscription'
      )
    )
  )
from public.profiles p
where p.id = '00000000-0000-0000-0000-00000000d201';

create temp table protected_before on commit drop as
select
  g.billing_subscription_id,
  g.xmin::text as gym_xmin,
  c.billing_key,
  c.xmin::text as credential_xmin,
  pa.billing_key_ref,
  pa.payment_key,
  pa.xmin::text as attempt_xmin
from public.profiles p
join public.gyms g on g.id = p.gym_id
join private.billing_credentials c on c.gym_id = p.gym_id
join public.payment_attempts pa on pa.order_id = 'synthetic-redaction-order'
where p.id = '00000000-0000-0000-0000-00000000d201';

create temp table privilege_before on commit drop as
select coalesce(string_agg(line, E'\n' order by line), '') as snapshot
from (
  select n.nspname || '.' || c.relname || ' relacl=' || coalesce(c.relacl::text, '') as line
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private')
    and c.relname in (
      'members', 'gyms', 'checkout_sessions', 'subscriptions',
      'payment_attempts', 'billing_credentials'
    )
  union all
  select n.nspname || '.' || c.relname || '.' || a.attname || ' attacl=' || coalesce(a.attacl::text, '')
  from pg_attribute a
  join pg_class c on c.oid = a.attrelid
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname in ('public', 'private')
    and c.relname in (
      'members', 'gyms', 'checkout_sessions', 'subscriptions',
      'payment_attempts', 'billing_credentials'
    )
    and a.attnum > 0
    and not a.attisdropped
) grants;

insert into redaction_results (test_name, status, detail)
select
  'insert redacts new keys and keeps payment facts',
  case
    when cs.raw ->> 'paymentKey' = '[REDACTED]'
     and cs.raw ->> 'payment_key' = '[REDACTED]'
     and cs.raw ->> 'lastTransactionKey' = '[REDACTED]'
     and cs.raw ->> 'transactionKey' = '[REDACTED]'
     and cs.raw ->> 'mId' = '[REDACTED]'
     and cs.raw ->> 'merchant_id' = '[REDACTED]'
     and cs.raw ->> 'approveNo' = '[REDACTED]'
     and cs.raw ->> 'approval_number' = '[REDACTED]'
     and cs.raw ->> 'receipt' = '[REDACTED]'
     and cs.raw ->> 'checkout_url' = '[REDACTED]'
     and cs.raw ->> 'secret' = '[REDACTED]'
     and cs.raw ->> 'orderId' = 'synthetic-redaction-checkout'
     and cs.raw ->> 'status' = 'DONE'
     and cs.raw ->> 'totalAmount' = '10000'
     and cs.raw ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and cs.raw ->> 'method' = 'card'
     and cs.raw ->> 'successUrl' = 'https://example.test/success-return'
     and cs.provider_session_id = 'synthetic-attempt-payment-key'
     and cs.raw::text not like '%synthetic-pay-checkout%'
     and cs.raw::text not like '%example.test/receipt/checkout%'
     and cs.raw::text not like '%example.test/checkout/flat%'
     and s.raw ->> 'payment_key' = '[REDACTED]'
     and s.raw ->> 'orderId' = 'synthetic-redaction-subscription'
     and s.raw ->> 'totalAmount' = '10000'
     and s.provider_ref = 'synthetic-attempt-payment-key'
     and s.raw #>> '{provider_response,payment,last_transaction_key}' = '[REDACTED]'
     and s.raw #>> '{provider_response,payment,receipt_url}' = '[REDACTED]'
     and s.raw::text not like '%synthetic-pay-subscription%'
     and s.raw::text not like '%example.test/receipt/subscription%'
     and pa.provider_response ->> 'paymentKey' = '[REDACTED]'
     and pa.provider_response ->> 'lastTransactionKey' = '[REDACTED]'
     and pa.provider_response ->> 'mId' = '[REDACTED]'
     and pa.provider_response ->> 'approveNo' = '[REDACTED]'
     and pa.provider_response ->> 'receipt' = '[REDACTED]'
     and pa.provider_response ->> 'checkout' = '[REDACTED]'
     and pa.provider_response ->> 'orderId' = 'synthetic-redaction-order'
     and pa.provider_response ->> 'status' = 'DONE'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and pa.provider_response #>> '{initial_reconciliation,result}' = 'payment_found'
     and pa.provider_response #>> '{reconciliation,status}' = 'claimed'
     and pa.payment_key = 'synthetic-attempt-payment-key'
     and pa.provider_response::text not like '%synthetic-pay-attempt%'
     and pa.provider_response::text not like '%example.test/receipt/attempt%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.checkout_sessions cs
join public.subscriptions s on s.provider_ref = 'synthetic-attempt-payment-key'
join public.payment_attempts pa on pa.order_id = 'synthetic-redaction-order'
where cs.order_id = 'synthetic-redaction-checkout';

update public.checkout_sessions
set raw = jsonb_build_object(
  'paymentKey', 'synthetic-pay-checkout-update',
  'lastTransactionKey', 'synthetic-txn-checkout-update',
  'mId', 'synthetic-mid-checkout-update',
  'approveNo', 'synthetic-approval-checkout-update',
  'receipt', jsonb_build_object('url', 'https://example.test/receipt/checkout-update'),
  'checkout', jsonb_build_object('url', 'https://example.test/checkout/checkout-update'),
  'orderId', 'synthetic-redaction-checkout',
  'totalAmount', 10000,
  'approvedAt', '2026-01-15T00:00:00Z'
)
where order_id = 'synthetic-redaction-checkout';

update public.subscriptions
set raw = jsonb_build_object(
  'payment_key', 'synthetic-pay-subscription-update',
  'orderId', 'synthetic-redaction-subscription',
  'totalAmount', 10000
)
where provider_ref = 'synthetic-attempt-payment-key';

update public.payment_attempts
set provider_response = jsonb_build_object(
  'paymentKey', 'synthetic-pay-attempt-update',
  'transaction_key', 'synthetic-txn-attempt-update',
  'merchantId', 'synthetic-merchant-attempt-update',
  'approvalNumber', 'synthetic-approval-attempt-update',
  'receiptUrl', 'https://example.test/receipt/attempt-update',
  'orderId', 'synthetic-redaction-order',
  'totalAmount', 10000,
  'initial_reconciliation', jsonb_build_object('result', 'payment_found')
)
where order_id = 'synthetic-redaction-order';

insert into redaction_results (test_name, status, detail)
select
  'update redacts new keys again',
  case
    when cs.raw ->> 'paymentKey' = '[REDACTED]'
     and cs.raw ->> 'lastTransactionKey' = '[REDACTED]'
     and cs.raw ->> 'mId' = '[REDACTED]'
     and cs.raw ->> 'approveNo' = '[REDACTED]'
     and cs.raw ->> 'receipt' = '[REDACTED]'
     and cs.raw ->> 'checkout' = '[REDACTED]'
     and cs.raw ->> 'orderId' = 'synthetic-redaction-checkout'
     and cs.raw ->> 'totalAmount' = '10000'
     and cs.raw ->> 'approvedAt' = '2026-01-15T00:00:00Z'
     and cs.provider_session_id = 'synthetic-attempt-payment-key'
     and cs.raw::text not like '%synthetic-pay-checkout-update%'
     and cs.raw::text not like '%example.test/checkout/checkout-update%'
     and s.raw ->> 'payment_key' = '[REDACTED]'
     and s.raw ->> 'orderId' = 'synthetic-redaction-subscription'
     and s.raw ->> 'totalAmount' = '10000'
     and s.provider_ref = 'synthetic-attempt-payment-key'
     and s.raw::text not like '%synthetic-pay-subscription-update%'
     and pa.provider_response ->> 'paymentKey' = '[REDACTED]'
     and pa.provider_response ->> 'transaction_key' = '[REDACTED]'
     and pa.provider_response ->> 'merchantId' = '[REDACTED]'
     and pa.provider_response ->> 'approvalNumber' = '[REDACTED]'
     and pa.provider_response ->> 'receiptUrl' = '[REDACTED]'
     and pa.provider_response ->> 'orderId' = 'synthetic-redaction-order'
     and pa.provider_response ->> 'totalAmount' = '10000'
     and pa.provider_response #>> '{initial_reconciliation,result}' = 'payment_found'
     and pa.payment_key = 'synthetic-attempt-payment-key'
     and pa.provider_response::text not like '%synthetic-pay-attempt-update%'
     and pa.provider_response::text not like '%example.test/receipt/attempt-update%'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.checkout_sessions cs
join public.subscriptions s on s.provider_ref = 'synthetic-attempt-payment-key'
join public.payment_attempts pa on pa.order_id = 'synthetic-redaction-order'
where cs.order_id = 'synthetic-redaction-checkout';

insert into redaction_results (test_name, status, detail)
select
  'billing credential and legacy billing reference stay byte-identical',
  case
    when g.billing_subscription_id = b.billing_subscription_id
     and convert_to(g.billing_subscription_id, 'UTF8') = convert_to(b.billing_subscription_id, 'UTF8')
     and g.xmin::text = b.gym_xmin
     and c.billing_key = b.billing_key
     and convert_to(c.billing_key, 'UTF8') = convert_to(b.billing_key, 'UTF8')
     and c.xmin::text = b.credential_xmin
     and pa.billing_key_ref = b.billing_key_ref
     and convert_to(pa.billing_key_ref, 'UTF8') = convert_to(b.billing_key_ref, 'UTF8')
     and pa.payment_key = b.payment_key
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from protected_before b
join public.profiles p on p.id = '00000000-0000-0000-0000-00000000d201'
join public.gyms g on g.id = p.gym_id
join private.billing_credentials c on c.gym_id = p.gym_id
join public.payment_attempts pa on pa.order_id = 'synthetic-redaction-order';

insert into redaction_results (test_name, status, detail)
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
            'members', 'gyms', 'checkout_sessions', 'subscriptions',
            'payment_attempts', 'billing_credentials'
          )
        union all
        select n.nspname || '.' || c.relname || '.' || a.attname || ' attacl=' || coalesce(a.attacl::text, '')
        from pg_attribute a
        join pg_class c on c.oid = a.attrelid
        join pg_namespace n on n.oid = c.relnamespace
        where n.nspname in ('public', 'private')
          and c.relname in (
            'members', 'gyms', 'checkout_sessions', 'subscriptions',
            'payment_attempts', 'billing_credentials'
          )
          and a.attnum > 0
          and not a.attisdropped
      ) grants
    )
     and has_column_privilege('authenticated', 'public.checkout_sessions', 'raw', 'select') = false
     and has_column_privilege('authenticated', 'public.checkout_sessions', 'order_id', 'select') = true
     and has_column_privilege('authenticated', 'public.payment_attempts', 'billing_key_ref', 'select') = false
     and has_column_privilege('authenticated', 'public.payment_attempts', 'payment_key', 'select') = true
     and has_column_privilege('authenticated', 'public.subscriptions', 'raw', 'select') = false
     and has_column_privilege('authenticated', 'public.subscriptions', 'status', 'select') = true
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from privilege_before;

select test_name, status, detail
from redaction_results
order by test_name;

rollback;
