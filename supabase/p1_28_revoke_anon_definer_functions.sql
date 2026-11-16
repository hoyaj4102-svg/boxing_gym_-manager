-- =============================================================================
-- Revoke anon execute on public security-definer functions, and pin search_path.
--
-- Preparation only. Applying this file changes function privileges and the
-- search_path setting. It does not update gyms, members, payments, or auth
-- users, and it does not replace function bodies.
--
-- Hosted Supabase grants execute on a new public function to anon,
-- authenticated, and service_role, in addition to the Postgres default
-- grant to public. A later "revoke from public" leaves that explicit anon
-- grant in place. After every migration on main, these five public
-- security-definer functions are still executable by anon on that hosted
-- privilege model:
--
--   public.current_gym_id()
--   public.enforce_member_limit()
--   public.gym_effective_member_limit(uuid)
--   public.handle_new_user()
--   public.record_attendance(uuid, date)
--
-- None of them is used before login. The logged-in app calls
-- record_attendance. Row level security for logged-in users calls
-- current_gym_id. gym_effective_member_limit stays executable by
-- authenticated, which is the grant the member-cap migration already
-- publishes. enforce_member_limit and handle_new_user are triggers.
-- Trigger execution does not consult the invoker's execute privilege, so
-- those two are revoked from public, anon, authenticated, and service_role.
-- No edge function calls any of the five. service_role therefore loses
-- execute on them as well.
--
-- keep_gym_updated_at_on_request() is not security definer. It was granted
-- to public. Execute is revoked from public, anon, and authenticated.
-- service_role keeps an explicit grant: that is the role that updates gyms.
-- The trigger itself fires without that grant. The grant is only so a
-- service-role update still holds execute if a later server checks it.
--
-- Five public functions have no fixed search_path. Their bodies use
-- pg_catalog (now, current_setting) or a schema-qualified name (auth.role),
-- so the setting is the empty search path. Bodies are not rewritten.
--
--   public.free_member_promo_ends_at()
--   public.gym_has_pro_access(public.gyms)
--   public.member_limit_now()
--   public.protect_gym_billing_columns()
--   public.set_updated_at()
--
-- Undo with supabase/p1_28_revoke_anon_definer_functions_rollback.sql.
-- Re-applying this file is safe.
-- =============================================================================

revoke all on function public.current_gym_id() from public;
revoke all on function public.current_gym_id() from anon;
revoke all on function public.current_gym_id() from service_role;
grant execute on function public.current_gym_id() to authenticated;

revoke all on function public.record_attendance(uuid, date) from public;
revoke all on function public.record_attendance(uuid, date) from anon;
revoke all on function public.record_attendance(uuid, date) from service_role;
grant execute on function public.record_attendance(uuid, date) to authenticated;

revoke all on function public.gym_effective_member_limit(uuid) from public;
revoke all on function public.gym_effective_member_limit(uuid) from anon;
revoke all on function public.gym_effective_member_limit(uuid) from service_role;
grant execute on function public.gym_effective_member_limit(uuid) to authenticated;

revoke all on function public.enforce_member_limit() from public;
revoke all on function public.enforce_member_limit() from anon;
revoke all on function public.enforce_member_limit() from authenticated;
revoke all on function public.enforce_member_limit() from service_role;

revoke all on function public.handle_new_user() from public;
revoke all on function public.handle_new_user() from anon;
revoke all on function public.handle_new_user() from authenticated;
revoke all on function public.handle_new_user() from service_role;

revoke all on function public.keep_gym_updated_at_on_request() from public;
revoke all on function public.keep_gym_updated_at_on_request() from anon;
revoke all on function public.keep_gym_updated_at_on_request() from authenticated;
grant execute on function public.keep_gym_updated_at_on_request() to service_role;

alter function public.free_member_promo_ends_at() set search_path = '';
alter function public.gym_has_pro_access(public.gyms) set search_path = '';
alter function public.member_limit_now() set search_path = '';
alter function public.protect_gym_billing_columns() set search_path = '';
alter function public.set_updated_at() set search_path = '';
