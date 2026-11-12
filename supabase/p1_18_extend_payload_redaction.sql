-- =============================================================================
-- Extend stored-payload redaction.
--
-- Webhook, reconciliation, renewal, and initial-billing code do not read
-- payment keys, transaction keys, approval numbers, receipt or checkout URLs,
-- or merchant ids from checkout raw, subscription raw, or payment-attempt
-- response JSON. Those flows use the live provider response, or the dedicated
-- payment_attempts.payment_key, checkout_sessions.provider_session_id,
-- subscriptions.provider_ref, and toss_webhook_events.payment_key columns.
-- Merchant comparison uses the function environment, not stored JSON.
-- No reader is switched. Reconciliation markers under initial_reconciliation
-- and reconciliation are not in this list.
--
-- This replaces only private.redact_sensitive_payload. Existing triggers call
-- that function on insert and update. It does not rewrite old rows, does not
-- read or write private.billing_credentials, does not change
-- payment_attempts.billing_key_ref, and does not change grants or charge flow.
-- Do not re-run the credential backfill as part of applying this file.
-- =============================================================================

create or replace function private.redact_sensitive_payload(p_value jsonb)
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
  v_sensitive text[] := array[
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
  ];
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
      v_result := v_result || jsonb_build_array(private.redact_sensitive_payload(v_item));
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
          private.redact_sensitive_payload(p_value -> v_key)
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

revoke all on function private.redact_sensitive_payload(jsonb) from public;
revoke all on function private.redact_sensitive_payload(jsonb) from anon, authenticated;
revoke all on function private.redact_sensitive_payload(jsonb) from service_role;
