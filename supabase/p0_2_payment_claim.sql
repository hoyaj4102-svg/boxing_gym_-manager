-- =============================================================================
-- Auto-renewal payment attempt claiming / duplicate charge prevention
-- Run after payment_attempts.sql
-- =============================================================================

-- Preflight before applying this migration in an existing database:
--
-- select
--   gym_id,
--   payment_type,
--   target_period_start,
--   target_period_end,
--   count(*)
-- from public.payment_attempts
-- where payment_type = 'auto_renewal'
--   and target_period_start is not null
-- group by
--   gym_id,
--   payment_type,
--   target_period_start,
--   target_period_end
-- having count(*) > 1;
--
-- The unique claim key below uses target_period_start because the existing
-- auto-renewal period end is intentionally calculated from the charge attempt
-- time and can differ between retrying workers.
--
-- select
--   gym_id,
--   payment_type,
--   target_period_start,
--   count(*)
-- from public.payment_attempts
-- where payment_type = 'auto_renewal'
--   and target_period_start is not null
-- group by
--   gym_id,
--   payment_type,
--   target_period_start
-- having count(*) > 1;

do $$
begin
  if exists (
    select 1
    from (
      select
        gym_id,
        payment_type,
        target_period_start,
        count(*) as attempt_count
      from public.payment_attempts
      where payment_type = 'auto_renewal'
        and target_period_start is not null
      group by
        gym_id,
        payment_type,
        target_period_start
      having count(*) > 1
    ) duplicates
  ) then
    raise exception 'DUPLICATE_AUTO_RENEWAL_PAYMENT_ATTEMPTS_EXIST';
  end if;
end;
$$;

create unique index if not exists payment_attempts_auto_renew_period_start_unique_idx
  on public.payment_attempts (
    gym_id,
    payment_type,
    target_period_start
  )
  where payment_type = 'auto_renewal'
    and target_period_start is not null;

create or replace function public.claim_due_toss_subscription_charges(
  p_now timestamptz default now(),
  p_limit integer default 50,
  p_amount_krw integer default 10000
)
returns table (
  payment_attempt_id uuid,
  gym_id uuid,
  user_id uuid,
  order_id text,
  customer_key text,
  billing_key_ref text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  amount_krw integer
)
language sql
security definer
set search_path = public
as $$
  with locked_due_gyms as (
    select
      g.id as gym_id,
      owner_profile.id as user_id,
      g.billing_customer_id as customer_key,
      g.billing_subscription_id as billing_key_ref,
      g.current_period_end as target_period_start
    from public.gyms g
    left join lateral (
      select p.id
      from public.profiles p
      where p.gym_id = g.id
      order by p.created_at asc
      limit 1
    ) owner_profile on true
    where g.billing_provider = 'toss'
      and g.auto_renew = true
      and g.subscription_status = 'active'
      and g.billing_customer_id is not null
      and g.billing_subscription_id is not null
      and g.current_period_end is not null
      and g.current_period_end <= p_now
    order by g.current_period_end asc, g.id asc
    limit greatest(least(coalesce(p_limit, 50), 100), 1)
    for update of g skip locked
  ),
  claim_rows as (
    select
      gen_random_uuid() as payment_attempt_id,
      gym_id,
      user_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      p_now + interval '30 days' as target_period_end,
      coalesce(p_amount_krw, 10000) as amount_krw
    from locked_due_gyms
  ),
  inserted_attempts as (
    insert into public.payment_attempts (
      id,
      gym_id,
      user_id,
      provider,
      payment_type,
      billing_interval,
      amount_krw,
      currency,
      order_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      target_period_end,
      status,
      activation_status,
      recovery_status,
      provider_response
    )
    select
      cr.payment_attempt_id,
      cr.gym_id,
      cr.user_id,
      'toss',
      'auto_renewal',
      'monthly',
      cr.amount_krw,
      'KRW',
      'toss_renew_' || replace(cr.payment_attempt_id::text, '-', ''),
      cr.customer_key,
      cr.billing_key_ref,
      cr.target_period_start,
      cr.target_period_end,
      'initiated',
      'not_started',
      'none',
      jsonb_build_object('mode', 'auto_renew_claim')
    from claim_rows cr
    on conflict do nothing
    returning
      id,
      gym_id,
      user_id,
      order_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      target_period_end,
      amount_krw
  )
  select
    ia.id as payment_attempt_id,
    ia.gym_id,
    ia.user_id,
    ia.order_id,
    ia.customer_key,
    ia.billing_key_ref,
    ia.target_period_start,
    ia.target_period_end,
    ia.amount_krw
  from inserted_attempts ia
  order by ia.target_period_start asc, ia.gym_id asc;
$$;

revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from public;
grant execute on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) to service_role;
