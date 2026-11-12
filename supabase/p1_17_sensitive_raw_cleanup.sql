-- =============================================================================
-- One-time cleanup of sensitive values stored in raw payment JSON.
--
-- Preparation only. Do not apply the data rewrite to production until the
-- Founder approves it. Installing this file with the four bounds left NULL
-- creates the functions and does not rewrite any row.
--
-- What it rewrites, and only this:
--   public.checkout_sessions.raw  where status = 'completed'
--   public.subscriptions.raw      for every status
-- Sensitive object keys are replaced with the existing '[REDACTED]' placeholder.
-- Status, amount, order id, timestamps, provider_session_id, and provider_ref
-- columns are not updated.
--
-- A count-only audit saw 6 completed checkout rows and 5 to 6 subscription
-- rows that still held sensitive raw keys. This file stores no identifiers.
-- Re-count immediately before apply and set the inclusive bounds below to
-- those counts. A non-zero count outside the bounds aborts the transaction
-- before any row is rewritten. When both target counts are already 0, the
-- call changes 0 rows so a repeated apply is safe. If the notice reports 0
-- updated rows, compare the verification totals with the database you
-- intended before treating the apply as complete.
--
-- This file does not read or write private.billing_credentials, does not
-- update payment_attempts.billing_key_ref, does not change grants, and does
-- not call the credential backfill.
-- =============================================================================

create or replace function private.stored_payload_sensitive_keys()
returns text[]
language sql
immutable
set search_path = private, public
as $$
  select array[
    'authkey',
    'authorization',
    'billingkey',
    'card',
    'cardno',
    'cardnumber',
    'customeremail',
    'customeridentitynumber',
    'customerkey',
    'customermobilephone',
    'customername',
    'secret',
    'secretkey',
    'approvalno',
    'approvalnumber',
    'approveno',
    'checkout',
    'checkouturl',
    'lasttransactionkey',
    'merchantid',
    'mid',
    'paymentkey',
    'receipt',
    'receipturl',
    'transactionkey'
  ]::text[];
$$;

revoke all on function private.stored_payload_sensitive_keys() from public;
revoke all on function private.stored_payload_sensitive_keys() from anon, authenticated;
revoke all on function private.stored_payload_sensitive_keys() from service_role;

create or replace function private.mask_sensitive_stored_payload(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = private, public
as $$
declare
  v_type text;
  v_key text;
  v_item jsonb;
  v_result jsonb;
  v_normalized text;
  v_sensitive text[] := private.stored_payload_sensitive_keys();
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return p_value;
  end if;

  v_type := jsonb_typeof(p_value);

  if v_type = 'array' then
    v_result := '[]'::jsonb;
    for v_item in
      select value
      from jsonb_array_elements(p_value)
    loop
      v_result := v_result || jsonb_build_array(private.mask_sensitive_stored_payload(v_item));
    end loop;
    return v_result;
  end if;

  if v_type = 'object' then
    v_result := '{}'::jsonb;
    for v_key in
      select jsonb_object_keys(p_value)
    loop
      v_normalized := lower(regexp_replace(v_key, '[_\-\s]', '', 'g'));
      if v_normalized = any (v_sensitive) then
        v_result := v_result || jsonb_build_object(v_key, '[REDACTED]');
      else
        v_result := v_result || jsonb_build_object(
          v_key,
          private.mask_sensitive_stored_payload(p_value -> v_key)
        );
      end if;
    end loop;
    return v_result;
  end if;

  if v_type = 'string'
     and btrim(p_value #>> '{}') ~ '^([0-9][ -]?){13,19}$' then
    return to_jsonb('[REDACTED]'::text);
  end if;

  return p_value;
end;
$$;

revoke all on function private.mask_sensitive_stored_payload(jsonb) from public;
revoke all on function private.mask_sensitive_stored_payload(jsonb) from anon, authenticated;
revoke all on function private.mask_sensitive_stored_payload(jsonb) from service_role;

create or replace function private.count_unredacted_sensitive_keys(p_value jsonb)
returns integer
language plpgsql
immutable
set search_path = private, public
as $$
declare
  v_type text;
  v_key text;
  v_item jsonb;
  v_count integer := 0;
  v_normalized text;
  v_sensitive text[] := private.stored_payload_sensitive_keys();
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return 0;
  end if;

  v_type := jsonb_typeof(p_value);

  if v_type = 'array' then
    for v_item in
      select value
      from jsonb_array_elements(p_value)
    loop
      v_count := v_count + private.count_unredacted_sensitive_keys(v_item);
    end loop;
    return v_count;
  end if;

  if v_type = 'object' then
    for v_key in
      select jsonb_object_keys(p_value)
    loop
      v_normalized := lower(regexp_replace(v_key, '[_\-\s]', '', 'g'));
      if v_normalized = any (v_sensitive) then
        if (p_value -> v_key) is distinct from to_jsonb('[REDACTED]'::text) then
          v_count := v_count + 1;
        end if;
      else
        v_count := v_count + private.count_unredacted_sensitive_keys(p_value -> v_key);
      end if;
    end loop;
    return v_count;
  end if;

  return 0;
end;
$$;

revoke all on function private.count_unredacted_sensitive_keys(jsonb) from public;
revoke all on function private.count_unredacted_sensitive_keys(jsonb) from anon, authenticated;
revoke all on function private.count_unredacted_sensitive_keys(jsonb) from service_role;

create or replace function private.apply_sensitive_raw_cleanup(
  p_completed_checkout_min integer,
  p_completed_checkout_max integer,
  p_subscription_min integer,
  p_subscription_max integer
)
returns table (
  completed_checkout_updated integer,
  subscriptions_updated integer
)
language plpgsql
set search_path = private, public
as $$
declare
  v_checkout_targets integer;
  v_subscription_targets integer;
  v_checkout_updated integer;
  v_subscription_updated integer;
begin
  if p_completed_checkout_min is null
     or p_completed_checkout_max is null
     or p_subscription_min is null
     or p_subscription_max is null
     or p_completed_checkout_min < 0
     or p_subscription_min < 0
     or p_completed_checkout_min > p_completed_checkout_max
     or p_subscription_min > p_subscription_max then
    raise exception 'SENSITIVE_RAW_CLEANUP_ABORTED bounds are missing or inverted';
  end if;

  lock table public.checkout_sessions in share row exclusive mode;
  lock table public.subscriptions in share row exclusive mode;

  select count(*)
  into v_checkout_targets
  from public.checkout_sessions
  where status = 'completed'
    and raw is distinct from private.mask_sensitive_stored_payload(raw);

  select count(*)
  into v_subscription_targets
  from public.subscriptions
  where raw is distinct from private.mask_sensitive_stored_payload(raw);

  raise notice
    'sensitive raw cleanup counts completed_checkout_targets=% subscription_targets=%',
    v_checkout_targets,
    v_subscription_targets;

  if v_checkout_targets = 0 and v_subscription_targets = 0 then
    completed_checkout_updated := 0;
    subscriptions_updated := 0;
    return next;
    return;
  end if;

  if v_checkout_targets < p_completed_checkout_min
     or v_checkout_targets > p_completed_checkout_max
     or v_subscription_targets < p_subscription_min
     or v_subscription_targets > p_subscription_max then
    raise exception
      'SENSITIVE_RAW_CLEANUP_ABORTED completed_checkout=% subscription=% expected_checkout=%..% expected_subscription=%..%',
      v_checkout_targets,
      v_subscription_targets,
      p_completed_checkout_min,
      p_completed_checkout_max,
      p_subscription_min,
      p_subscription_max;
  end if;

  update public.checkout_sessions
  set raw = private.mask_sensitive_stored_payload(raw)
  where status = 'completed'
    and raw is distinct from private.mask_sensitive_stored_payload(raw);
  get diagnostics v_checkout_updated = row_count;

  update public.subscriptions
  set raw = private.mask_sensitive_stored_payload(raw)
  where raw is distinct from private.mask_sensitive_stored_payload(raw);
  get diagnostics v_subscription_updated = row_count;

  completed_checkout_updated := v_checkout_updated;
  subscriptions_updated := v_subscription_updated;
  return next;
end;
$$;

revoke all on function private.apply_sensitive_raw_cleanup(integer, integer, integer, integer) from public;
revoke all on function private.apply_sensitive_raw_cleanup(integer, integer, integer, integer) from anon, authenticated;
revoke all on function private.apply_sensitive_raw_cleanup(integer, integer, integer, integer) from service_role;

create or replace function private.sensitive_raw_cleanup_verification()
returns table (
  metric text,
  row_count bigint
)
language sql
stable
set search_path = private, public
as $$
  select 'billing_credential_rows'::text, count(*)::bigint
  from private.billing_credentials
  union all
  select 'checkout_order_id_present'::text, count(*)::bigint
  from public.checkout_sessions
  where order_id is not null
  union all
  select 'checkout_provider_session_id_present'::text, count(*)::bigint
  from public.checkout_sessions
  where provider_session_id is not null
  union all
  select 'checkout_rows'::text, count(*)::bigint
  from public.checkout_sessions
  union all
  select 'checkout_status_' || s.status, count(c.id)::bigint
  from (
    values ('pending'), ('completed'), ('failed'), ('canceled'), ('expired')
  ) as s(status)
  left join public.checkout_sessions c on c.status = s.status
  group by s.status
  union all
  select 'completed_checkout_rows_redaction_would_change'::text, count(*)::bigint
  from public.checkout_sessions
  where status = 'completed'
    and raw is distinct from private.mask_sensitive_stored_payload(raw)
  union all
  select 'completed_checkout_unredacted_sensitive_keys'::text,
         coalesce(sum(private.count_unredacted_sensitive_keys(raw)), 0)::bigint
  from public.checkout_sessions
  where status = 'completed'
  union all
  select 'non_completed_checkout_unredacted_sensitive_keys'::text,
         coalesce(sum(private.count_unredacted_sensitive_keys(raw)), 0)::bigint
  from public.checkout_sessions
  where status <> 'completed'
  union all
  select 'payment_attempt_billing_key_ref_present'::text, count(*)::bigint
  from public.payment_attempts
  where billing_key_ref is not null
  union all
  select 'payment_attempt_payment_key_present'::text, count(*)::bigint
  from public.payment_attempts
  where payment_key is not null
  union all
  select 'subscription_provider_ref_present'::text, count(*)::bigint
  from public.subscriptions
  where provider_ref is not null
  union all
  select 'subscription_rows'::text, count(*)::bigint
  from public.subscriptions
  union all
  select 'subscription_rows_redaction_would_change'::text, count(*)::bigint
  from public.subscriptions
  where raw is distinct from private.mask_sensitive_stored_payload(raw)
  union all
  select 'subscription_status_' || s.status, count(sub.id)::bigint
  from (
    values ('trialing'), ('active'), ('past_due'), ('canceled'), ('expired')
  ) as s(status)
  left join public.subscriptions sub on sub.status = s.status
  group by s.status
  union all
  select 'subscription_unredacted_sensitive_keys'::text,
         coalesce(sum(private.count_unredacted_sensitive_keys(raw)), 0)::bigint
  from public.subscriptions;
$$;

revoke all on function private.sensitive_raw_cleanup_verification() from public;
revoke all on function private.sensitive_raw_cleanup_verification() from anon, authenticated;
revoke all on function private.sensitive_raw_cleanup_verification() from service_role;

-- Reviewer: set these four integers, then run this file again.
-- Leave them NULL and this block does not rewrite any row.
-- Audit, counts only: 6 completed checkout rows, and 5 to 6 subscription rows.
do $$
declare
  c_completed_checkout_min integer := null;
  c_completed_checkout_max integer := null;
  c_subscription_min integer := null;
  c_subscription_max integer := null;
  v_checkout_updated integer;
  v_subscription_updated integer;
begin
  if c_completed_checkout_min is null
     or c_completed_checkout_max is null
     or c_subscription_min is null
     or c_subscription_max is null then
    raise notice 'sensitive raw cleanup not executed: reviewer bounds are unset';
    return;
  end if;

  select completed_checkout_updated, subscriptions_updated
  into v_checkout_updated, v_subscription_updated
  from private.apply_sensitive_raw_cleanup(
    c_completed_checkout_min,
    c_completed_checkout_max,
    c_subscription_min,
    c_subscription_max
  );

  raise notice
    'sensitive raw cleanup updated completed_checkout=% subscription=%',
    v_checkout_updated,
    v_subscription_updated;
end
$$;
