-- =============================================================================
-- Mask sensitive keys already stored on payment_attempts.provider_response.
--
-- private.redact_sensitive_payload is the helper the payment-attempt trigger
-- already calls. Its key list is not copied here. Checkout raw and
-- subscription raw were rewritten by the earlier cleanup. This file rewrites
-- payment attempt responses only.
--
-- One transaction. No backup of previous JSON. A second run updates 0 rows.
-- Status, amount, payment_key, billing_key_ref, timestamps, and every other
-- column stay as they are. Other tables are not updated.
--
-- payment_attempts_redact_payload already runs before insert and before
-- update of provider_response. If that trigger is missing, this file creates
-- the same definition. It does not replace the helper or the trigger function.
--
-- The updated_at trigger is disabled only while this rewrite holds an
-- exclusive lock, then enabled again before the function returns. Stale-claim
-- windows keep the previous timestamp.
--
-- This file does not read or write private.billing_credentials and does not
-- change grants on existing tables.
-- Do not apply this file to production until a separate approval.
-- =============================================================================

begin;

do $$
declare
  v_def text;
begin
  select pg_get_triggerdef(t.oid)
  into v_def
  from pg_trigger t
  join pg_class c on c.oid = t.tgrelid
  join pg_namespace n on n.oid = c.relnamespace
  where t.tgname = 'payment_attempts_redact_payload'
    and n.nspname = 'public'
    and c.relname = 'payment_attempts'
    and not t.tgisinternal;

  if v_def is null then
    create trigger payment_attempts_redact_payload
    before insert or update of provider_response on public.payment_attempts
    for each row
    execute function private.redact_payment_row();
  elsif v_def not ilike '%before insert or update of provider_response%'
     or v_def not ilike '%redact_payment_row%' then
    raise exception 'payment_attempts_redact_payload does not cover provider_response';
  end if;
end
$$;

create or replace function private.apply_payment_attempt_provider_response_redaction()
returns integer
language plpgsql
set search_path = private, public
as $$
declare
  v_updated integer := 0;
begin
  lock table public.payment_attempts in access exclusive mode;
  alter table public.payment_attempts disable trigger payment_attempts_set_updated_at;

  update public.payment_attempts
  set provider_response = private.redact_sensitive_payload(provider_response)
  where provider_response is distinct from private.redact_sensitive_payload(provider_response);
  get diagnostics v_updated = row_count;

  alter table public.payment_attempts enable trigger payment_attempts_set_updated_at;
  return v_updated;
exception
  when others then
    alter table public.payment_attempts enable trigger payment_attempts_set_updated_at;
    raise;
end;
$$;

revoke all on function private.apply_payment_attempt_provider_response_redaction() from public;
revoke all on function private.apply_payment_attempt_provider_response_redaction() from anon, authenticated;
revoke all on function private.apply_payment_attempt_provider_response_redaction() from service_role;

do $$
declare
  v_updated integer;
begin
  v_updated := private.apply_payment_attempt_provider_response_redaction();
  raise notice
    'payment attempt provider_response redaction updated=%',
    v_updated;
end
$$;

commit;
