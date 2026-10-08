-- =============================================================================
-- P1-7B Initial billing reconciliation claim
-- Looks up stale uncertain initial billing attempts by stable Toss orderId before
-- allowing any new initial charge path.
-- =============================================================================

create or replace function public.claim_stale_initial_billing_reconciliation_attempts(
  p_stale_before timestamptz,
  p_limit integer default 50
)
returns table (
  id uuid,
  gym_id uuid,
  user_id uuid,
  order_id text,
  amount_krw integer,
  customer_key text,
  billing_key_ref text,
  status text,
  activation_status text,
  recovery_status text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  provider_response jsonb,
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
      and pa.payment_type = 'initial_billing'
      and pa.payment_key is null
      and pa.status in ('initiated', 'auth_issued', 'charge_failed', 'charge_succeeded')
      and pa.created_at <= p_stale_before
      and pa.recovery_status in ('none', 'pending')
      and (
        pa.recovery_status = 'none'
        or pa.updated_at <= p_stale_before
      )
      and not (
        pa.recovery_status = 'completed'
        and pa.provider_response #>> '{initial_reconciliation,result}' = 'confirmed_no_payment'
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
        'initial_reconciliation', jsonb_build_object(
          'result', 'claimed',
          'claimed_at', now(),
          'order_id', pa.order_id
        )
      )
  from locked_attempts la
  where pa.id = la.id
  returning
    pa.id,
    pa.gym_id,
    pa.user_id,
    pa.order_id,
    pa.amount_krw,
    pa.customer_key,
    pa.billing_key_ref,
    pa.status,
    pa.activation_status,
    pa.recovery_status,
    pa.target_period_start,
    pa.target_period_end,
    pa.provider_response,
    pa.created_at,
    pa.updated_at;
$$;

revoke all on function public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer) from public;
revoke all on function public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer) from anon, authenticated;
grant execute on function public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer) to service_role;
