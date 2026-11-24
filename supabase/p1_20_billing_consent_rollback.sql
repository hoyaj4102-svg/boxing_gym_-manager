-- =============================================================================
-- Rollback for p1_20 billing consent.
--
-- Re-applying this file is safe. It drops only:
--   public.billing_charge_consent_gate(uuid, integer, text)
--   public.get_billing_readiness()
--   public.record_billing_consent(text, text, uuid)
--   public.billing_subject_granted(uuid, text, timestamptz, uuid)
--   public.billing_latest_decision(uuid, text, timestamptz, uuid)
--   public.billing_consent_in_window(timestamptz, timestamptz)
--   policy "Gym can view own billing consents"
--   table public.billing_consents
--   table public.billing_price_schedules
--
-- It does not update gyms, profiles, members, payments, or auth users.
-- =============================================================================

drop function if exists public.billing_charge_consent_gate(uuid, integer, text);
drop function if exists public.get_billing_readiness();
drop function if exists public.record_billing_consent(text, text, uuid);
drop function if exists public.billing_subject_granted(uuid, text, timestamptz, uuid);
drop function if exists public.billing_latest_decision(uuid, text, timestamptz, uuid);
drop function if exists public.billing_consent_in_window(timestamptz, timestamptz);

do $p1_20_rollback$
begin
  if to_regclass('public.billing_consents') is not null then
    execute 'drop policy if exists "Gym can view own billing consents" on public.billing_consents';
  end if;
end
$p1_20_rollback$;

drop table if exists public.billing_consents;
drop table if exists public.billing_price_schedules;
