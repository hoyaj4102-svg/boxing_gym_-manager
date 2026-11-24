-- =============================================================================
-- Rollback for p1_30 signup acquisition.
--
-- Re-applying this file is safe. It drops only:
--   trigger auth.users.on_auth_user_created_acquisition
--   public.record_signup_acquisition()
--   public.signup_acquisition_clean(jsonb)
--   public.signup_acquisition_path(text)
--   public.signup_acquisition_domain(text)
--   public.signup_acquisition_token(text)
--   table public.signup_acquisitions
--
-- It does not update gyms, profiles, members, payments, or auth users.
-- Signup continues to create a gym through handle_new_user.
-- =============================================================================

drop trigger if exists on_auth_user_created_acquisition on auth.users;

drop function if exists public.record_signup_acquisition();
drop function if exists public.signup_acquisition_clean(jsonb);
drop function if exists public.signup_acquisition_path(text);
drop function if exists public.signup_acquisition_domain(text);
drop function if exists public.signup_acquisition_token(text);

drop table if exists public.signup_acquisitions;
