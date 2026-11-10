-- Remove client writes on payment-related tables.
-- requires Founder approval before applying to production
-- Does not move or delete existing payment data.

create or replace function private.enforce_payment_table_write_restrictions()
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  revoke insert, update, delete, truncate, references, trigger
    on table public.gyms
    from public, anon, authenticated;
  revoke insert, update, delete, truncate, references, trigger
    on table public.payment_attempts
    from public, anon, authenticated;
  revoke insert, update, delete, truncate, references, trigger
    on table public.checkout_sessions
    from public, anon, authenticated;
  revoke insert, update, delete, truncate, references, trigger
    on table public.subscriptions
    from public, anon, authenticated;
  revoke insert, update, delete, truncate, references, trigger
    on table public.toss_webhook_events
    from public, anon, authenticated;
  revoke insert, update, delete, truncate, references, trigger
    on table private.billing_credentials
    from public, anon, authenticated;

  grant select, insert, update, delete on table public.gyms to service_role;
  grant select, insert, update, delete on table public.payment_attempts to service_role;
  grant select, insert, update, delete on table public.checkout_sessions to service_role;
  grant select, insert, update, delete on table public.subscriptions to service_role;
  grant select, insert, update on table public.toss_webhook_events to service_role;
  grant select, insert, update, delete on table private.billing_credentials to service_role;
end;
$$;

revoke all on function private.enforce_payment_table_write_restrictions() from public;
revoke all on function private.enforce_payment_table_write_restrictions() from anon, authenticated;
revoke all on function private.enforce_payment_table_write_restrictions() from service_role;

select private.enforce_payment_table_write_restrictions();
