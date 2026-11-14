-- =============================================================================
-- Rollback for the free member cap promo.
--
-- Re-applying this file is safe. It restores the previous effective limit
-- (Pro access unlimited, otherwise 20) and drops the promo clock helpers.
-- It does not update gyms, members, or payments, and it does not change
-- signup, the trial, or charging.
-- Run it only to undo supabase/p1_26_free_member_cap_promo.sql before the
-- cutoff. From 2027-01-01 00:00:00+09 the forward migration already matches
-- this limit, so this file is the early undo.
-- =============================================================================

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

drop function if exists public.member_limit_now();
drop function if exists public.free_member_promo_ends_at();
