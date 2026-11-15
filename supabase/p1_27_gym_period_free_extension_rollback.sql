-- =============================================================================
-- Rollback for the free period extension.
--
-- Re-applying this file is safe. It drops the bookkeeping trigger added by
-- supabase/p1_27_gym_period_free_extension.sql and drops only these
-- functions:
--   keep_gym_updated_at_on_request
--   extend_gym_period_free
--   revert_gym_period_free_extension
-- It does not update gyms, members, payment attempts, or subscription
-- history, and it does not replace any pre-existing function.
-- A history row already written by an extension call stays until
-- revert_gym_period_free_extension is called, and only before this file
-- drops that function.
-- =============================================================================

drop trigger if exists gyms_zz_keep_updated_at on public.gyms;
drop function if exists public.keep_gym_updated_at_on_request();
drop function if exists public.extend_gym_period_free(uuid, timestamptz, timestamptz, text);
drop function if exists public.revert_gym_period_free_extension(uuid, timestamptz);
