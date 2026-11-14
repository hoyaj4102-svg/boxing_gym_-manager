-- =============================================================================
-- P1-26 free member cap promo
-- =============================================================================
--
-- Preparation only. Do not apply this file to production until a separate
-- approval. It does not update gyms, members, or payments. It does not change
-- signup, the 14-day trial, or any charge.
--
-- Until 2027-01-01 00:00:00 Asia/Seoul, gym_effective_member_limit returns -1
-- for every existing gym. That instant is 2026-12-31 23:59:59 KST plus the
-- rest of that second. From 2027-01-01 00:00:00+09 the previous rule returns:
-- Pro access is unlimited, and every other gym is capped at 20.
--
-- The insert trigger and restore_gym_members_from_json already call
-- gym_effective_member_limit, so both follow this cutoff. The gyms.member_limit
-- column is not read and is not updated. Writers that store 20 on a downgrade
-- do not re-impose the cap during the promo.
--
-- member_limit_now() is the clock for this check. It returns transaction
-- now(). It is not a session setting. Only the function owner can replace it.
-- Remove this migration with supabase/p1_26_free_member_cap_promo_rollback.sql.
-- =============================================================================

create or replace function public.free_member_promo_ends_at()
returns timestamptz
language sql
immutable
as $$
  select timestamptz '2027-01-01 00:00:00+09';
$$;

revoke all on function public.free_member_promo_ends_at() from public;
revoke all on function public.free_member_promo_ends_at() from anon, authenticated;

create or replace function public.member_limit_now()
returns timestamptz
language sql
stable
as $$
  select now();
$$;

comment on function public.member_limit_now() is
  'Clock for the free-member promo. Returns transaction now(). Not a client setting.';

revoke all on function public.member_limit_now() from public;
revoke all on function public.member_limit_now() from anon, authenticated;

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

  -- Inclusive through 2026-12-31 23:59:59 KST. The next instant restores 20.
  if public.member_limit_now() < public.free_member_promo_ends_at() then
    return -1;
  end if;

  return 20;
end;
$$;

comment on function public.gym_effective_member_limit(uuid) is
  'Unlimited for Pro access. Unlimited for every gym before 2027-01-01 00:00:00+09. Otherwise 20.';

revoke all on function public.gym_effective_member_limit(uuid) from public;
grant execute on function public.gym_effective_member_limit(uuid) to authenticated;
