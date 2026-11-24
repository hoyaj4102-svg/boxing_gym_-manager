-- =============================================================================
-- Rollback for p1_21 test-mode refund and payment-failure records.
--
-- Re-applying this file is safe. It drops only:
--   public.mark_billing_notification_read(uuid)
--   public.get_billing_ops_status()
--   public.claim_due_payment_failure_retries(timestamptz, integer)
--   public.record_billing_refund_result(uuid, text, text, boolean)
--   public.load_billing_refund_for_cancel(uuid, uuid, uuid)
--   public.create_billing_refund_request(uuid, text, integer, boolean)
--   public.resolve_attempt_payment_key(uuid)
--   public.record_payment_failure(uuid, uuid, timestamptz, text)
--   public.evaluate_draft_refund(timestamptz, timestamptz, integer, integer, text, boolean)
--   policy "Gym can view own billing notifications"
--   policy "Gym can view own refund requests"
--   table public.billing_refund_requests
--   table public.billing_notifications
--   table public.billing_payment_failures
--
-- It does not update gyms, profiles, members, payment attempts, or auth users.
-- =============================================================================

drop function if exists public.mark_billing_notification_read(uuid);
drop function if exists public.get_billing_ops_status();
drop function if exists public.claim_due_payment_failure_retries(timestamptz, integer);
drop function if exists public.record_billing_refund_result(uuid, text, text, boolean);
drop function if exists public.load_billing_refund_for_cancel(uuid, uuid, uuid);
drop function if exists public.create_billing_refund_request(uuid, text, integer, boolean);
drop function if exists public.resolve_attempt_payment_key(uuid);
drop function if exists public.record_payment_failure(uuid, uuid, timestamptz, text);
drop function if exists public.evaluate_draft_refund(timestamptz, timestamptz, integer, integer, text, boolean);

do $p1_21_rollback$
begin
  if to_regclass('public.billing_notifications') is not null then
    execute 'drop policy if exists "Gym can view own billing notifications" on public.billing_notifications';
  end if;
  if to_regclass('public.billing_refund_requests') is not null then
    execute 'drop policy if exists "Gym can view own refund requests" on public.billing_refund_requests';
  end if;
end
$p1_21_rollback$;

drop table if exists public.billing_refund_requests;
drop table if exists public.billing_notifications;
drop table if exists public.billing_payment_failures;
