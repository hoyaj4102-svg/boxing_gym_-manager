-- One dispatch record per auto-renewal attempt.
-- requires Founder approval before applying to production
-- This does not call a payment provider and does not schedule charges.

alter table public.payment_attempts
  add column if not exists charge_dispatched_at timestamptz;

create or replace function public.claim_subscription_charge_dispatch(
  p_attempt_id uuid
)
returns boolean
language plpgsql
security invoker
set search_path = public
as $$
declare
  v_id uuid;
begin
  update public.payment_attempts
  set charge_dispatched_at = now()
  where id = p_attempt_id
    and payment_type = 'auto_renewal'
    and status = 'initiated'
    and charge_dispatched_at is null
  returning id into v_id;

  return v_id is not null;
end;
$$;

revoke all on function public.claim_subscription_charge_dispatch(uuid) from public;
revoke all on function public.claim_subscription_charge_dispatch(uuid) from anon, authenticated;
grant execute on function public.claim_subscription_charge_dispatch(uuid) to service_role;
