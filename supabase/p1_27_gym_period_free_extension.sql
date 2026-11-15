-- =============================================================================
-- Free period extension for a paid gym while recurring billing is paused.
-- =============================================================================
--
-- Preparation only. Applying this file creates two functions and one
-- before-update trigger. It does not update a gym, insert a history row,
-- or read a billing credential. The gym id is an argument and is not stored
-- in this file.
--
--   select public.extend_gym_period_free(
--     '<gym id>'::uuid,
--     '<current period end>'::timestamptz,
--     '<new period end>'::timestamptz,
--     '<reason>'
--   );
--
-- The call locks that gym and writes nothing unless all of the following hold:
--   exactly one gym
--   plan_code = pro
--   subscription_status = active
--   complimentary_pro = false
--   no in-progress payment attempt for that gym
--   new end is later than the current end, at most 90 days later, and after now()
--   current end equals the expected end
--
-- An in-progress attempt is one billing claim or recovery can still act on:
-- initiated, auth_issued, charge_succeeded, activation_pending,
-- activation_failed, recovery_pending, charge_failed while recovery is
-- pending, or completed while activation has not succeeded. A completed
-- success and a charge_failed attempt whose recovery is not pending are
-- closed and do not block the call.
--
-- The only gym column written is current_period_end. auto_renew, plan,
-- status, the complimentary marker, customer ids, and credential columns
-- are not selected and are not changed. gyms_set_updated_at would also
-- stamp updated_at. gyms_zz_keep_updated_at runs after that trigger and,
-- only when app.preserve_updated_at is 1, puts the previous updated_at
-- back. With the setting unset, gym updates behave as they do today.
--
-- History is one public.subscriptions row, not a payment attempt:
--   amount_krw = 0
--   provider = manual
--   provider_ref is null
--   started_at = previous end
--   ends_at = new end
--   raw.reason = free_period_extension
--   raw.previous_period_end, raw.new_period_end, raw.note
-- Auto-renewal reconciliation, initial-billing reconciliation, and
-- get_payment_history read public.payment_attempts only. They do not treat
-- this zero-amount manual audit row as a charge to settle. It is the same
-- kind of row apply_complimentary_pro already writes.
--
-- Calling extend again with the same expected end, new end, and reason,
-- after the row is already in place, returns a no-op and does not insert
-- another row.
--
-- Undo one extension with
-- public.revert_gym_period_free_extension(gym_id, extended_end).
-- It restores the previous end from that history row and deletes the row.
-- It refuses when a successful payment attempt was recorded after the
-- extension, or when the same guards as extend fail.
-- Remove this migration with
-- supabase/p1_27_gym_period_free_extension_rollback.sql.
-- =============================================================================

create or replace function public.keep_gym_updated_at_on_request()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if tg_op = 'UPDATE'
     and current_setting('app.preserve_updated_at', true) = '1' then
    new.updated_at := old.updated_at;
  end if;

  return new;
end;
$$;

comment on function public.keep_gym_updated_at_on_request() is
  'Trigger function. When app.preserve_updated_at is 1, keeps gyms.updated_at. Direct calls are rejected.';

-- Trigger functions must stay executable by every role that can update gyms.
grant execute on function public.keep_gym_updated_at_on_request() to public;

drop trigger if exists gyms_zz_keep_updated_at on public.gyms;
create trigger gyms_zz_keep_updated_at
before update on public.gyms
for each row
execute function public.keep_gym_updated_at_on_request();


create or replace function public.extend_gym_period_free(
  p_gym_id uuid,
  p_expected_current_end timestamptz,
  p_new_end timestamptz,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_targets integer;
  v_plan_code text;
  v_subscription_status text;
  v_complimentary_pro boolean;
  v_current_end timestamptz;
  v_updated_at timestamptz;
  v_reason text := btrim(p_reason);
  v_matches integer;
  v_history_count integer;
  v_updated integer;
  v_seen_end timestamptz;
  v_seen_updated timestamptz;
begin
  if p_gym_id is null then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  if v_reason is null or length(v_reason) = 0 or length(v_reason) > 200 then
    raise exception 'GYM_PERIOD_EXTENSION_REASON_REQUIRED';
  end if;

  if p_new_end is null then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:NOT_LATER';
  end if;

  if p_expected_current_end is null then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END';
  end if;

  select count(*)
  into v_targets
  from public.gyms
  where id = p_gym_id;

  if v_targets <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  select
    g.plan_code,
    g.subscription_status,
    g.complimentary_pro,
    g.current_period_end,
    g.updated_at
  into
    v_plan_code,
    v_subscription_status,
    v_complimentary_pro,
    v_current_end,
    v_updated_at
  from public.gyms g
  where g.id = p_gym_id
  for update;

  if v_plan_code is distinct from 'pro' then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:PLAN';
  end if;

  if v_subscription_status is distinct from 'active' then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:STATUS';
  end if;

  if v_complimentary_pro then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:COMPLIMENTARY';
  end if;

  if exists (
    select 1
    from public.payment_attempts pa
    where pa.gym_id = p_gym_id
      and pa.recovery_status is distinct from 'failed'
      and not (
        pa.status = 'completed'
        and pa.activation_status = 'succeeded'
        and pa.recovery_status is distinct from 'pending'
      )
      and not (
        pa.status = 'charge_failed'
        and pa.recovery_status is distinct from 'pending'
      )
  ) then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:ATTEMPT_IN_PROGRESS';
  end if;

  select count(*)
  into v_matches
  from public.subscriptions s
  where s.gym_id = p_gym_id
    and s.amount_krw = 0
    and s.provider = 'manual'
    and s.provider_ref is null
    and s.plan_code = 'pro'
    and s.status = 'active'
    and s.started_at = p_expected_current_end
    and s.ends_at = p_new_end
    and s.raw->>'reason' = 'free_period_extension'
    and s.raw->>'note' = v_reason
    and (s.raw->>'previous_period_end')::timestamptz = p_expected_current_end
    and (s.raw->>'new_period_end')::timestamptz = p_new_end;

  if v_current_end = p_new_end and v_matches = 1 then
    select count(*)
    into v_history_count
    from public.subscriptions s
    where s.gym_id = p_gym_id
      and s.amount_krw = 0
      and s.provider = 'manual'
      and s.raw->>'reason' = 'free_period_extension';

    return jsonb_build_object(
      'before_end', p_expected_current_end,
      'after_end', p_new_end,
      'history_count', v_history_count,
      'noop', true
    );
  end if;

  if v_current_end = p_new_end and v_matches > 1 then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:HISTORY';
  end if;

  if v_current_end is distinct from p_expected_current_end then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END';
  end if;

  if p_new_end <= v_current_end then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:NOT_LATER';
  end if;

  if p_new_end > v_current_end + interval '90 days' then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:WINDOW';
  end if;

  if p_new_end <= now() then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:NOT_FUTURE';
  end if;

  perform set_config('app.allow_billing_update', '1', true);
  perform set_config('app.preserve_updated_at', '1', true);

  update public.gyms
  set current_period_end = p_new_end
  where id = p_gym_id
    and plan_code = 'pro'
    and subscription_status = 'active'
    and complimentary_pro = false
    and current_period_end = p_expected_current_end;

  get diagnostics v_updated = row_count;

  perform set_config('app.allow_billing_update', '', true);
  perform set_config('app.preserve_updated_at', '', true);

  if v_updated <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  select g.current_period_end, g.updated_at
  into v_seen_end, v_seen_updated
  from public.gyms g
  where g.id = p_gym_id;

  if v_seen_end is distinct from p_new_end
     or v_seen_updated is distinct from v_updated_at then
    raise exception 'GYM_PERIOD_EXTENSION_ROW_MISMATCH';
  end if;

  insert into public.subscriptions (
    gym_id,
    plan_code,
    status,
    provider,
    provider_ref,
    amount_krw,
    started_at,
    ends_at,
    raw
  )
  values (
    p_gym_id,
    'pro',
    'active',
    'manual',
    null,
    0,
    v_current_end,
    p_new_end,
    jsonb_build_object(
      'reason', 'free_period_extension',
      'previous_period_end', v_current_end,
      'new_period_end', p_new_end,
      'note', v_reason
    )
  );

  select count(*)
  into v_history_count
  from public.subscriptions s
  where s.gym_id = p_gym_id
    and s.amount_krw = 0
    and s.provider = 'manual'
    and s.raw->>'reason' = 'free_period_extension';

  return jsonb_build_object(
    'before_end', v_current_end,
    'after_end', p_new_end,
    'history_count', v_history_count,
    'noop', false
  );
end;
$$;

comment on function public.extend_gym_period_free(uuid, timestamptz, timestamptz, text) is
  'Moves one paid gym period end later and writes one zero-amount manual history row. Does not read billing credentials.';

revoke all on function public.extend_gym_period_free(uuid, timestamptz, timestamptz, text) from public;
revoke all on function public.extend_gym_period_free(uuid, timestamptz, timestamptz, text) from anon, authenticated;
grant execute on function public.extend_gym_period_free(uuid, timestamptz, timestamptz, text) to service_role;


create or replace function public.revert_gym_period_free_extension(
  p_gym_id uuid,
  p_expected_current_end timestamptz
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_targets integer;
  v_plan_code text;
  v_subscription_status text;
  v_complimentary_pro boolean;
  v_current_end timestamptz;
  v_updated_at timestamptz;
  v_matches integer;
  v_history_id uuid;
  v_previous_end timestamptz;
  v_history_created_at timestamptz;
  v_started_at timestamptz;
  v_ends_at timestamptz;
  v_raw jsonb;
  v_history_count integer;
  v_updated integer;
  v_seen_end timestamptz;
  v_seen_updated timestamptz;
begin
  if p_gym_id is null then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  if p_expected_current_end is null then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END';
  end if;

  select count(*)
  into v_targets
  from public.gyms
  where id = p_gym_id;

  if v_targets <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  select
    g.plan_code,
    g.subscription_status,
    g.complimentary_pro,
    g.current_period_end,
    g.updated_at
  into
    v_plan_code,
    v_subscription_status,
    v_complimentary_pro,
    v_current_end,
    v_updated_at
  from public.gyms g
  where g.id = p_gym_id
  for update;

  if v_plan_code is distinct from 'pro' then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:PLAN';
  end if;

  if v_subscription_status is distinct from 'active' then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:STATUS';
  end if;

  if v_complimentary_pro then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:COMPLIMENTARY';
  end if;

  if v_current_end is distinct from p_expected_current_end then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END';
  end if;

  if exists (
    select 1
    from public.payment_attempts pa
    where pa.gym_id = p_gym_id
      and pa.recovery_status is distinct from 'failed'
      and not (
        pa.status = 'completed'
        and pa.activation_status = 'succeeded'
        and pa.recovery_status is distinct from 'pending'
      )
      and not (
        pa.status = 'charge_failed'
        and pa.recovery_status is distinct from 'pending'
      )
  ) then
    raise exception 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:ATTEMPT_IN_PROGRESS';
  end if;

  select count(*)
  into v_matches
  from public.subscriptions s
  where s.gym_id = p_gym_id
    and s.amount_krw = 0
    and s.provider = 'manual'
    and s.provider_ref is null
    and s.plan_code = 'pro'
    and s.status = 'active'
    and s.ends_at = p_expected_current_end
    and s.raw->>'reason' = 'free_period_extension'
    and (s.raw->>'new_period_end')::timestamptz = p_expected_current_end;

  if v_matches <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:HISTORY';
  end if;

  select
    s.id,
    s.started_at,
    s.ends_at,
    s.created_at,
    s.raw
  into
    v_history_id,
    v_started_at,
    v_ends_at,
    v_history_created_at,
    v_raw
  from public.subscriptions s
  where s.gym_id = p_gym_id
    and s.amount_krw = 0
    and s.provider = 'manual'
    and s.provider_ref is null
    and s.plan_code = 'pro'
    and s.status = 'active'
    and s.ends_at = p_expected_current_end
    and s.raw->>'reason' = 'free_period_extension'
    and (s.raw->>'new_period_end')::timestamptz = p_expected_current_end
  for update;

  if not found then
    raise exception 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:HISTORY';
  end if;

  v_previous_end := (v_raw->>'previous_period_end')::timestamptz;

  if v_previous_end is null
     or v_previous_end is distinct from v_started_at
     or v_previous_end >= p_expected_current_end
     or v_ends_at is distinct from p_expected_current_end
     or (v_raw->>'new_period_end')::timestamptz is distinct from p_expected_current_end then
    raise exception 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:HISTORY';
  end if;

  if exists (
    select 1
    from public.payment_attempts pa
    where pa.gym_id = p_gym_id
      and pa.status = 'completed'
      and pa.activation_status = 'succeeded'
      and coalesce(pa.activated_at, pa.created_at) > v_history_created_at
  ) then
    raise exception 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:LATER_PAYMENT';
  end if;

  perform set_config('app.allow_billing_update', '1', true);
  perform set_config('app.preserve_updated_at', '1', true);

  update public.gyms
  set current_period_end = v_previous_end
  where id = p_gym_id
    and plan_code = 'pro'
    and subscription_status = 'active'
    and complimentary_pro = false
    and current_period_end = p_expected_current_end;

  get diagnostics v_updated = row_count;

  perform set_config('app.allow_billing_update', '', true);
  perform set_config('app.preserve_updated_at', '', true);

  if v_updated <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_TARGET_COUNT';
  end if;

  select g.current_period_end, g.updated_at
  into v_seen_end, v_seen_updated
  from public.gyms g
  where g.id = p_gym_id;

  if v_seen_end is distinct from v_previous_end
     or v_seen_updated is distinct from v_updated_at then
    raise exception 'GYM_PERIOD_EXTENSION_ROW_MISMATCH';
  end if;

  delete from public.subscriptions
  where id = v_history_id
    and gym_id = p_gym_id
    and amount_krw = 0
    and provider = 'manual'
    and provider_ref is null
    and raw->>'reason' = 'free_period_extension';

  get diagnostics v_updated = row_count;
  if v_updated <> 1 then
    raise exception 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:HISTORY';
  end if;

  select count(*)
  into v_history_count
  from public.subscriptions s
  where s.gym_id = p_gym_id
    and s.amount_krw = 0
    and s.provider = 'manual'
    and s.raw->>'reason' = 'free_period_extension';

  return jsonb_build_object(
    'before_end', p_expected_current_end,
    'after_end', v_previous_end,
    'history_count', v_history_count,
    'noop', false
  );
end;
$$;

comment on function public.revert_gym_period_free_extension(uuid, timestamptz) is
  'Restores the previous period end from one zero-amount free-extension history row and deletes that row.';

revoke all on function public.revert_gym_period_free_extension(uuid, timestamptz) from public;
revoke all on function public.revert_gym_period_free_extension(uuid, timestamptz) from anon, authenticated;
grant execute on function public.revert_gym_period_free_extension(uuid, timestamptz) to service_role;
