-- =============================================================================
-- Rollback for the anon security-definer revoke.
--
-- Re-applying this file is safe. It restores the hosted execute grants that
-- were in place after p1_27, including the explicit anon, authenticated, and
-- service_role grants Supabase adds when a public function is created, and
-- it clears the empty search_path pinned by p1_28.
--
-- It does not replace function bodies and does not update gyms, members,
-- payments, or auth users.
--
-- A database that never had those default-privilege grants (the local test
-- database) did not list anon or service_role on current_gym_id,
-- record_attendance, or gym_effective_member_limit before p1_28. This file
-- still restores the hosted grants, because that is the privilege set the
-- forward migration removes.
-- =============================================================================

revoke all on function public.current_gym_id() from public;
grant execute on function public.current_gym_id() to anon, authenticated, service_role;

revoke all on function public.record_attendance(uuid, date) from public;
grant execute on function public.record_attendance(uuid, date) to anon, authenticated, service_role;

revoke all on function public.gym_effective_member_limit(uuid) from public;
grant execute on function public.gym_effective_member_limit(uuid) to anon, authenticated, service_role;

grant execute on function public.enforce_member_limit() to public, anon, authenticated, service_role;

grant execute on function public.handle_new_user() to public, anon, authenticated, service_role;

grant execute on function public.keep_gym_updated_at_on_request() to public, anon, authenticated, service_role;

alter function public.free_member_promo_ends_at() reset search_path;
alter function public.gym_has_pro_access(public.gyms) reset search_path;
alter function public.member_limit_now() reset search_path;
alter function public.protect_gym_billing_columns() reset search_path;
alter function public.set_updated_at() reset search_path;
