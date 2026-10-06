-- =============================================================================
-- P1-1 auto-renewal reconciliation claim
-- Run after p0_2_payment_claim.sql
-- =============================================================================

create or replace function public.claim_stale_auto_renewal_reconciliation_attempts(
  p_stale_before timestamptz,
  p_limit integer default 50
)
returns table (
  id uuid,
  gym_id uuid,
  order_id text,
  amount_krw integer,
  customer_key text,
  billing_key_ref text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language sql
security definer
set search_path = public
as $$
  with locked_attempts as (
    select pa.id
    from public.payment_attempts pa
    where pa.provider = 'toss'
      and pa.payment_type = 'auto_renewal'
      and pa.status = 'initiated'
      and pa.payment_key is null
      and pa.created_at <= p_stale_before
      and pa.recovery_status in ('none', 'pending')
      and (
        pa.recovery_status = 'none'
        or pa.updated_at <= p_stale_before
      )
    order by pa.created_at asc, pa.id asc
    limit greatest(least(coalesce(p_limit, 50), 50), 1)
    for update skip locked
  )
  update public.payment_attempts pa
  set
    recovery_status = 'pending',
    error_code = null,
    error_message = null,
    provider_response = coalesce(pa.provider_response, '{}'::jsonb)
      || jsonb_build_object(
        'reconciliation', jsonb_build_object(
          'status', 'claimed',
          'claimed_at', now()
        )
      )
  from locked_attempts la
  where pa.id = la.id
  returning
    pa.id,
    pa.gym_id,
    pa.order_id,
    pa.amount_krw,
    pa.customer_key,
    pa.billing_key_ref,
    pa.target_period_start,
    pa.target_period_end,
    pa.created_at,
    pa.updated_at;
$$;

revoke all on function public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer) from public;
grant execute on function public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer) to service_role;
