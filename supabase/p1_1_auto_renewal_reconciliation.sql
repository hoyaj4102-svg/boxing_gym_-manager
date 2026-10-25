-- =============================================================================
-- P1-1 auto-renewal reconciliation claim
-- Run after p0_2_payment_claim.sql
-- =============================================================================

drop function if exists public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer);

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
  status text,
  activation_status text,
  recovery_status text,
  payment_key text,
  reconciliation_action text,
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
      and (
        (
          pa.status in ('initiated', 'charge_failed')
          and pa.payment_key is null
        )
        or (
          pa.status in ('activation_pending', 'activation_failed', 'recovery_pending', 'charge_succeeded')
          and pa.payment_key is not null
        )
      )
      and not (
        pa.status = 'completed'
        and pa.activation_status = 'succeeded'
      )
      and pa.updated_at <= p_stale_before
      and pa.recovery_status in ('none', 'pending')
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
    pa.status,
    pa.activation_status,
    pa.recovery_status,
    pa.payment_key,
    case
      when pa.status in ('initiated', 'charge_failed') and pa.payment_key is null then 'lookup_required'
      else 'recovery_only'
    end as reconciliation_action,
    pa.target_period_start,
    pa.target_period_end,
    pa.created_at,
    pa.updated_at;
$$;

revoke all on function public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer) from public;
revoke all on function public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer) from anon, authenticated;
grant execute on function public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer) to service_role;
