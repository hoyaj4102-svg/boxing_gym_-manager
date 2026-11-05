-- =============================================================================
-- Rollback for the payment-data SQL.
--
-- Re-applying this file is safe. It copies private values back when the
-- previous column is empty or already equal, restores owner table reads,
-- and removes the payload triggers. It does not delete gyms, members, or
-- payment rows.
--
-- After this file, re-apply these existing files in this order so the
-- previous function bodies are restored:
--   1. supabase/monthly_billing.sql
--   2. supabase/p1_5_calendar_month_billing.sql
--
-- Recommended rollback order is the reverse of apply order:
--   1. Deploy the previous functions first.
--   2. Run supabase/p1_15a_expired_pro_billing_claim_rollback.sql
--   3. Run this file, then the two files above.
-- =============================================================================

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set billing_subscription_id = c.billing_key
from private.billing_credentials c
where c.gym_id = g.id
  and c.provider = 'toss'
  and coalesce(g.billing_provider, 'toss') = 'toss'
  and (
    g.billing_subscription_id is null
    or length(btrim(g.billing_subscription_id)) = 0
    or btrim(g.billing_subscription_id) = c.billing_key
  );

drop trigger if exists checkout_sessions_redact_payload on public.checkout_sessions;
drop trigger if exists payment_attempts_redact_payload on public.payment_attempts;
drop trigger if exists subscriptions_redact_payload on public.subscriptions;

grant select on table public.gyms to anon, authenticated;
grant select on table public.payment_attempts to anon, authenticated;
grant select on table public.checkout_sessions to anon, authenticated;
grant select on table public.subscriptions to anon, authenticated;
