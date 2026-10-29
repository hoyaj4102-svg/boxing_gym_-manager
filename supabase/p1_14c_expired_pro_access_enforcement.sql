-- =============================================================================
-- P1-14C expired Pro access enforcement
-- =============================================================================
--
-- Run after billing.sql, cancel_subscription.sql, and monthly_billing.sql.
--
-- This migration is intentionally idempotent. It changes entitlement checks only:
-- it does not update gyms, delete members, call payment APIs, or alter billing
-- renewal/recovery state.

create or replace function public.gym_has_pro_access(p_gym public.gyms)
returns boolean
language sql
stable
as $$
  select
    case
      when p_gym.subscription_status = 'trialing'
           and p_gym.trial_ends_at > now() then true
      when p_gym.plan_code = 'pro'
           and p_gym.subscription_status = 'active'
           and p_gym.current_period_end is not null
           and p_gym.current_period_end > now() then true
      when p_gym.plan_code = 'pro'
           and p_gym.subscription_status = 'canceled'
           and p_gym.current_period_end is not null
           and p_gym.current_period_end > now() then true
      else false
    end
$$;

create or replace function public.gym_effective_member_limit(p_gym_id uuid)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym from public.gyms where id = p_gym_id;
  if not found then
    return 0;
  end if;

  if public.gym_has_pro_access(v_gym) then
    return -1;
  end if;

  return 20;
end;
$$;

revoke all on function public.gym_effective_member_limit(uuid) from public;
grant execute on function public.gym_effective_member_limit(uuid) to authenticated;
