-- Synthetic privilege and regression checks. This script rolls back.
-- Ids are generated here. No production row is read or written.
-- No payment provider is called.

begin;

set local timezone to 'UTC';

create temp table p1_28_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create or replace function pg_temp.p1_28_grantees(p_func regprocedure)
returns text
language sql
stable
set search_path = pg_catalog
as $$
  select coalesce(string_agg(role_name, ',' order by role_name), '')
  from (
    select coalesce(r.rolname, 'public') as role_name
    from pg_catalog.pg_proc p
    cross join lateral pg_catalog.aclexplode(p.proacl) as a
    left join pg_catalog.pg_roles r on r.oid = a.grantee
    where p.oid = p_func
      and a.privilege_type = 'EXECUTE'
      and a.grantee is distinct from p.proowner
  ) granted
$$;

create or replace function pg_temp.p1_28_search_path_fixed(p_func regprocedure)
returns boolean
language sql
stable
set search_path = pg_catalog
as $$
  select exists (
    select 1
    from pg_catalog.pg_proc p
    cross join lateral unnest(coalesce(p.proconfig, array[]::text[])) as cfg
    where p.oid = p_func
      and cfg = 'search_path=""'
  )
$$;

create or replace function pg_temp.p1_28_call_error(p_role text, p_sql text)
returns text
language plpgsql
set search_path = pg_catalog
as $$
begin
  execute format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  return 'call returned';
exception when others then
  execute 'reset role';
  return sqlerrm;
end;
$$;

revoke all on function pg_temp.p1_28_grantees(regprocedure) from public;
revoke all on function pg_temp.p1_28_search_path_fixed(regprocedure) from public;
revoke all on function pg_temp.p1_28_call_error(text, text) from public;

create temp table p1_28_context (
  user_id uuid not null,
  gym_id uuid not null,
  member_id uuid not null,
  signup_user_id uuid not null
) on commit drop;

insert into p1_28_context
values (gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid());

alter table auth.users disable trigger on_auth_user_created;

insert into auth.users (
  id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  ctx.user_id,
  'authenticated',
  'authenticated',
  'p1-28-owner@example.invalid',
  '',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_28_context ctx;

alter table auth.users enable trigger on_auth_user_created;

insert into public.gyms (
  id, name, owner_name, phone, plan_code, member_limit, subscription_status,
  trial_ends_at, current_period_end, auto_renew, complimentary_pro
)
select
  ctx.gym_id,
  'P1-28 Synthetic Gym',
  'Synthetic Owner',
  '000-000-0000',
  'free',
  20,
  'expired',
  now() - interval '30 days',
  null,
  false,
  false
from p1_28_context ctx;

insert into public.profiles (id, gym_id, name)
select ctx.user_id, ctx.gym_id, 'Synthetic Owner'
from p1_28_context ctx;

insert into public.members (id, gym_id, name, start_date, expire_date)
select ctx.member_id, ctx.gym_id, 'P1-28 Attendance Member', current_date, current_date + 30
from p1_28_context ctx;

insert into p1_28_results (test_name, status, detail)
select
  'security-definer anon execute is removed and needed grants remain',
  case
    when pg_temp.p1_28_grantees('public.current_gym_id()') = 'authenticated'
     and has_function_privilege('anon', 'public.current_gym_id()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.current_gym_id()', 'EXECUTE') = true
     and has_function_privilege('service_role', 'public.current_gym_id()', 'EXECUTE') = false
     and has_function_privilege('public', 'public.current_gym_id()', 'EXECUTE') = false
     and pg_temp.p1_28_grantees('public.record_attendance(uuid, date)') = 'authenticated'
     and has_function_privilege('anon', 'public.record_attendance(uuid, date)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.record_attendance(uuid, date)', 'EXECUTE') = true
     and has_function_privilege('service_role', 'public.record_attendance(uuid, date)', 'EXECUTE') = false
     and pg_temp.p1_28_grantees('public.gym_effective_member_limit(uuid)') = 'authenticated'
     and has_function_privilege('anon', 'public.gym_effective_member_limit(uuid)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.gym_effective_member_limit(uuid)', 'EXECUTE') = true
     and has_function_privilege('service_role', 'public.gym_effective_member_limit(uuid)', 'EXECUTE') = false
     and pg_temp.p1_28_grantees('public.enforce_member_limit()') = ''
     and has_function_privilege('anon', 'public.enforce_member_limit()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.enforce_member_limit()', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.enforce_member_limit()', 'EXECUTE') = false
     and has_function_privilege('public', 'public.enforce_member_limit()', 'EXECUTE') = false
     and pg_temp.p1_28_grantees('public.handle_new_user()') = ''
     and has_function_privilege('anon', 'public.handle_new_user()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.handle_new_user()', 'EXECUTE') = false
     and has_function_privilege('public', 'public.handle_new_user()', 'EXECUTE') = false
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_28_grantees('public.current_gym_id()')
    || ' | ' || pg_temp.p1_28_grantees('public.record_attendance(uuid, date)')
    || ' | ' || pg_temp.p1_28_grantees('public.gym_effective_member_limit(uuid)')
    || ' | ' || pg_temp.p1_28_grantees('public.enforce_member_limit()')
    || ' | ' || pg_temp.p1_28_grantees('public.handle_new_user()');

insert into p1_28_results (test_name, status, detail)
select
  'gym updated_at trigger is not executable by public, anon, or authenticated',
  case
    when pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()') = 'service_role'
     and has_function_privilege('public', 'public.keep_gym_updated_at_on_request()', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.keep_gym_updated_at_on_request()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.keep_gym_updated_at_on_request()', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.keep_gym_updated_at_on_request()', 'EXECUTE') = true
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()');

insert into p1_28_results (test_name, status, detail)
select
  'functions that had no search_path now pin an empty search_path',
  case
    when pg_temp.p1_28_search_path_fixed('public.free_member_promo_ends_at()')
     and pg_temp.p1_28_search_path_fixed('public.gym_has_pro_access(public.gyms)')
     and pg_temp.p1_28_search_path_fixed('public.member_limit_now()')
     and pg_temp.p1_28_search_path_fixed('public.protect_gym_billing_columns()')
     and pg_temp.p1_28_search_path_fixed('public.set_updated_at()')
     and public.free_member_promo_ends_at() = timestamptz '2027-01-01 00:00:00+09'
     and public.member_limit_now() <= now()
     and public.gym_has_pro_access(g) = false
    then 'PASS' else 'FAIL'
  end,
  public.free_member_promo_ends_at()::text
from public.gyms g
join p1_28_context ctx on ctx.gym_id = g.id;

insert into p1_28_results (test_name, status, detail)
select
  'anon cannot call the revoked functions',
  case
    when anon_current ilike 'permission denied for function current_gym_id'
     and anon_limit ilike 'permission denied for function gym_effective_member_limit'
     and anon_attendance ilike 'permission denied for function record_attendance'
     and anon_enforce ilike 'permission denied for function enforce_member_limit'
     and anon_signup ilike 'permission denied for function handle_new_user'
     and anon_touch ilike 'permission denied for function keep_gym_updated_at_on_request'
     and auth_enforce ilike 'permission denied for function enforce_member_limit'
     and svc_attendance ilike 'permission denied for function record_attendance'
     and svc_signup ilike 'permission denied for function handle_new_user'
     and svc_touch ilike '%trigger%'
     and svc_touch not ilike 'permission denied%'
    then 'PASS' else 'FAIL'
  end,
  anon_limit || ' / touch ' || anon_touch || ' / service touch ' || svc_touch
from (
  select
    pg_temp.p1_28_call_error('anon', 'select public.current_gym_id()') as anon_current,
    pg_temp.p1_28_call_error(
      'anon',
      format('select public.gym_effective_member_limit(%L::uuid)', ctx.gym_id)
    ) as anon_limit,
    pg_temp.p1_28_call_error(
      'anon',
      format('select public.record_attendance(%L::uuid, current_date)', ctx.member_id)
    ) as anon_attendance,
    pg_temp.p1_28_call_error('anon', 'select public.enforce_member_limit()') as anon_enforce,
    pg_temp.p1_28_call_error('anon', 'select public.handle_new_user()') as anon_signup,
    pg_temp.p1_28_call_error('anon', 'select public.keep_gym_updated_at_on_request()') as anon_touch,
    pg_temp.p1_28_call_error('authenticated', 'select public.enforce_member_limit()') as auth_enforce,
    pg_temp.p1_28_call_error(
      'service_role',
      format('select public.record_attendance(%L::uuid, current_date)', ctx.member_id)
    ) as svc_attendance,
    pg_temp.p1_28_call_error('service_role', 'select public.handle_new_user()') as svc_signup,
    pg_temp.p1_28_call_error('service_role', 'select public.keep_gym_updated_at_on_request()') as svc_touch
  from p1_28_context ctx
) calls;

select set_config('request.jwt.claim.sub', (select user_id::text from p1_28_context), true);
select set_config('request.jwt.claim.role', 'authenticated', true);

do $$
declare
  v_user uuid;
  v_gym uuid;
  v_member uuid;
  v_seen_gym uuid;
  v_limit integer;
  v_visits integer;
  v_attendance integer;
  v_summary jsonb;
  v_current_error text;
  v_limit_error text;
  v_attendance_error text;
  v_summary_error text;
begin
  select user_id, gym_id, member_id
  into v_user, v_gym, v_member
  from p1_28_context;

  begin
    execute 'set local role authenticated';
    v_seen_gym := public.current_gym_id();
    v_limit := public.gym_effective_member_limit(v_gym);
    execute 'reset role';
    v_current_error := 'ok';
    v_limit_error := 'ok';
  exception when others then
    execute 'reset role';
    v_current_error := sqlerrm;
    v_limit_error := sqlerrm;
    v_seen_gym := null;
    v_limit := null;
  end;

  begin
    execute 'set local role authenticated';
    perform public.record_attendance(v_member, current_date);
    execute 'reset role';
    v_attendance_error := 'ok';
  exception when others then
    execute 'reset role';
    v_attendance_error := sqlerrm;
  end;

  select m.total_visits into v_visits
  from public.members m
  where m.id = v_member;

  select count(*) into v_attendance
  from public.attendance a
  where a.member_id = v_member;

  begin
    execute 'set local role authenticated';
    v_summary := public.get_billing_summary();
    execute 'reset role';
    v_summary_error := 'ok';
  exception when others then
    execute 'reset role';
    v_summary_error := sqlerrm;
  end;

  insert into p1_28_results
  values (
    'authenticated still resolves the gym, the limit, and attendance',
    case
      when v_current_error = 'ok'
       and v_seen_gym = v_gym
       and v_limit_error = 'ok'
       and v_limit = -1
       and v_attendance_error = 'ok'
       and v_visits = 1
       and v_attendance = 1
       and v_summary_error = 'ok'
       and v_summary->>'member_count' = '1'
       and v_summary->>'member_limit' = '-1'
       and v_summary->>'has_pro' = 'false'
       and v_summary->>'can_add_member' = 'true'
       and v_summary->>'plan_code' = 'free'
      then 'PASS' else 'FAIL'
    end,
    coalesce(v_current_error, '') || ' limit ' || coalesce(v_limit::text, 'null')
      || ' attendance ' || coalesce(v_attendance_error, '')
      || ' summary ' || coalesce(v_summary_error, '') || ' ' || coalesce(v_summary::text, 'null')
  );
end;
$$;

create or replace function public.member_limit_now()
returns timestamptz
language sql
stable
as $$ select timestamptz '2027-01-01 00:00:00+09' $$;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.gym_id, 'P1-28 Cap ' || gs, current_date, current_date + 30
from p1_28_context ctx
cross join generate_series(1, 19) as gs;

do $$
declare
  v_message text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select gym_id, 'P1-28 Over Cap', current_date, current_date + 30
    from p1_28_context;
    v_message := 'insert succeeded';
  exception when others then
    v_message := sqlerrm;
  end;

  select count(*) into v_count
  from public.members m
  join p1_28_context ctx on ctx.gym_id = m.gym_id;

  insert into p1_28_results
  values (
    'member insert still stops at 20 after the promo cutoff',
    case
      when v_message ilike 'MEMBER_LIMIT_REACHED:20%'
       and v_count = 20
       and public.gym_effective_member_limit((select gym_id from p1_28_context)) = 20
      then 'PASS' else 'FAIL'
    end,
    v_message || ' count ' || v_count::text
  );
end;
$$;

grant select, insert on table public.members to authenticated;

do $$
declare
  v_gym uuid;
  v_message text;
  v_count integer;
begin
  select gym_id into v_gym from p1_28_context;

  begin
    execute 'set local role authenticated';
    insert into public.members (gym_id, name, start_date, expire_date)
    values (v_gym, 'P1-28 Authenticated Over Cap', current_date, current_date + 30);
    execute 'reset role';
    v_message := 'insert succeeded';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  select count(*) into v_count
  from public.members m
  join p1_28_context ctx on ctx.gym_id = m.gym_id;

  insert into p1_28_results
  values (
    'logged-in member insert still hits the limit without execute on the trigger',
    case
      when v_message ilike 'MEMBER_LIMIT_REACHED:20%'
       and v_message not ilike 'permission denied%'
       and v_count = 20
      then 'PASS' else 'FAIL'
    end,
    v_message
  );
end;
$$;

create or replace function public.member_limit_now()
returns timestamptz
language sql
stable
as $$ select timestamptz '2026-12-31 23:59:59+09' $$;

do $$
declare
  v_gym uuid;
  v_message text;
  v_count integer;
begin
  select gym_id into v_gym from p1_28_context;

  begin
    execute 'set local role authenticated';
    insert into public.members (gym_id, name, start_date, expire_date)
    values (v_gym, 'P1-28 Authenticated During Promo', current_date, current_date + 30);
    execute 'reset role';
    v_message := 'insert succeeded';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  select count(*) into v_count
  from public.members m
  join p1_28_context ctx on ctx.gym_id = m.gym_id;

  insert into p1_28_results
  values (
    'logged-in member insert still succeeds during the promo',
    case
      when v_message = 'insert succeeded'
       and v_count = 21
       and public.gym_effective_member_limit((select gym_id from p1_28_context)) = -1
      then 'PASS' else 'FAIL'
    end,
    v_message || ' count ' || coalesce(v_count::text, 'null')
  );
end;
$$;

do $$
declare
  v_gym uuid;
  v_old timestamptz;
  v_new timestamptz;
  v_phone text;
  v_plan text;
  v_status text;
  v_kept timestamptz;
  v_message text;
begin
  select gym_id into v_gym from p1_28_context;

  execute 'set local session_replication_role to replica';
  update public.gyms
  set updated_at = now() - interval '2 days'
  where id = v_gym;
  execute 'set local session_replication_role to origin';

  select updated_at into v_old from public.gyms where id = v_gym;

  update public.gyms
  set phone = '000-000-0001',
      plan_code = 'pro'
  where id = v_gym;

  select updated_at, phone, plan_code
  into v_new, v_phone, v_plan
  from public.gyms
  where id = v_gym;

  perform set_config('app.preserve_updated_at', '1', true);
  perform set_config('request.jwt.claim.role', 'service_role', true);

  begin
    execute 'set local role service_role';
    update public.gyms
    set phone = '000-000-0002',
        subscription_status = 'past_due'
    where id = v_gym;
    execute 'reset role';
    v_message := 'updated';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  select updated_at, phone, subscription_status
  into v_kept, v_phone, v_status
  from public.gyms
  where id = v_gym;

  perform set_config('request.jwt.claim.role', 'authenticated', true);

  perform set_config('app.preserve_updated_at', '', true);

  insert into p1_28_results
  values (
    'gym triggers still protect billing fields and can preserve updated_at',
    case
      when v_phone = '000-000-0002'
       and v_plan = 'free'
       and v_new > v_old
       and v_message = 'updated'
       and v_status = 'past_due'
       and v_kept = v_new
      then 'PASS' else 'FAIL'
    end,
    coalesce(v_message, '')
      || ' plan ' || coalesce(v_plan, '')
      || ' status ' || coalesce(v_status, '')
      || ' phone ' || coalesce(v_phone, '')
  );
end;
$$;

grant usage on schema auth to authenticated;
grant insert on table auth.users to authenticated;

do $$
declare
  v_user uuid;
  v_gym uuid;
  v_message text;
  v_name text;
begin
  select signup_user_id into v_user from p1_28_context;

  begin
    execute 'set local role authenticated';
    insert into auth.users (
      id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
    )
    values (
      v_user,
      'authenticated',
      'authenticated',
      'p1-28-signup@example.invalid',
      '',
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb,
      '{"gym_name":"P1-28 Signup Gym","owner_name":"Synthetic Owner"}'::jsonb
    );
    execute 'reset role';
    v_message := 'inserted';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  select p.gym_id, g.name
  into v_gym, v_name
  from public.profiles p
  join public.gyms g on g.id = p.gym_id
  where p.id = v_user;

  insert into p1_28_results
  values (
    'signup trigger still creates a gym without execute on the trigger function',
    case
      when v_message = 'inserted'
       and v_gym is not null
       and v_name = 'P1-28 Signup Gym'
       and has_function_privilege('authenticated', 'public.handle_new_user()', 'EXECUTE') = false
      then 'PASS' else 'FAIL'
    end,
    coalesce(v_message, '') || ' name ' || coalesce(v_name, 'null')
  );
end;
$$;

\ir p1_28_revoke_anon_definer_functions_rollback.sql

insert into p1_28_results (test_name, status, detail)
select
  'rollback restores the hosted grants and clears the pinned search_path',
  case
    when pg_temp.p1_28_grantees('public.current_gym_id()') = 'anon,authenticated,service_role'
     and has_function_privilege('public', 'public.current_gym_id()', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.current_gym_id()', 'EXECUTE') = true
     and pg_temp.p1_28_grantees('public.record_attendance(uuid, date)') = 'anon,authenticated,service_role'
     and pg_temp.p1_28_grantees('public.gym_effective_member_limit(uuid)') = 'anon,authenticated,service_role'
     and pg_temp.p1_28_grantees('public.enforce_member_limit()') = 'anon,authenticated,public,service_role'
     and has_function_privilege('anon', 'public.enforce_member_limit()', 'EXECUTE') = true
     and pg_temp.p1_28_grantees('public.handle_new_user()') = 'anon,authenticated,public,service_role'
     and pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()') = 'anon,authenticated,public,service_role'
     and not pg_temp.p1_28_search_path_fixed('public.free_member_promo_ends_at()')
     and not pg_temp.p1_28_search_path_fixed('public.gym_has_pro_access(public.gyms)')
     and not pg_temp.p1_28_search_path_fixed('public.member_limit_now()')
     and not pg_temp.p1_28_search_path_fixed('public.protect_gym_billing_columns()')
     and not pg_temp.p1_28_search_path_fixed('public.set_updated_at()')
     and public.free_member_promo_ends_at() = timestamptz '2027-01-01 00:00:00+09'
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_28_grantees('public.current_gym_id()')
    || ' | ' || pg_temp.p1_28_grantees('public.enforce_member_limit()')
    || ' | ' || pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()');

insert into p1_28_results (test_name, status, detail)
select
  'rollback lets anon call the member limit again',
  case
    when anon_limit = 'call returned'
     and public.gym_effective_member_limit(ctx.gym_id) = -1
    then 'PASS' else 'FAIL'
  end,
  anon_limit
from p1_28_context ctx
cross join lateral (
  select pg_temp.p1_28_call_error(
    'anon',
    format('select public.gym_effective_member_limit(%L::uuid)', ctx.gym_id)
  ) as anon_limit
) calls;

\ir p1_28_revoke_anon_definer_functions.sql

insert into p1_28_results (test_name, status, detail)
select
  'reapplying the migration removes anon execute and pins search_path again',
  case
    when pg_temp.p1_28_grantees('public.current_gym_id()') = 'authenticated'
     and pg_temp.p1_28_grantees('public.record_attendance(uuid, date)') = 'authenticated'
     and pg_temp.p1_28_grantees('public.gym_effective_member_limit(uuid)') = 'authenticated'
     and pg_temp.p1_28_grantees('public.enforce_member_limit()') = ''
     and pg_temp.p1_28_grantees('public.handle_new_user()') = ''
     and pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()') = 'service_role'
     and has_function_privilege('anon', 'public.gym_effective_member_limit(uuid)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.record_attendance(uuid, date)', 'EXECUTE') = true
     and pg_temp.p1_28_search_path_fixed('public.free_member_promo_ends_at()')
     and pg_temp.p1_28_search_path_fixed('public.gym_has_pro_access(public.gyms)')
     and pg_temp.p1_28_search_path_fixed('public.member_limit_now()')
     and pg_temp.p1_28_search_path_fixed('public.protect_gym_billing_columns()')
     and pg_temp.p1_28_search_path_fixed('public.set_updated_at()')
     and anon_limit ilike 'permission denied for function gym_effective_member_limit'
    then 'PASS' else 'FAIL'
  end,
  anon_limit
from p1_28_context ctx
cross join lateral (
  select pg_temp.p1_28_call_error(
    'anon',
    format('select public.gym_effective_member_limit(%L::uuid)', ctx.gym_id)
  ) as anon_limit
) calls;

\ir p1_28_revoke_anon_definer_functions.sql

insert into p1_28_results (test_name, status, detail)
select
  'applying the migration twice leaves the same grants',
  case
    when pg_temp.p1_28_grantees('public.current_gym_id()') = 'authenticated'
     and pg_temp.p1_28_grantees('public.gym_effective_member_limit(uuid)') = 'authenticated'
     and pg_temp.p1_28_grantees('public.enforce_member_limit()') = ''
     and pg_temp.p1_28_grantees('public.handle_new_user()') = ''
     and pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()') = 'service_role'
     and pg_temp.p1_28_search_path_fixed('public.set_updated_at()')
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_28_grantees('public.keep_gym_updated_at_on_request()');

do $$
declare
  v_member uuid;
  v_message text;
  v_count integer;
begin
  select member_id into v_member from p1_28_context;

  begin
    execute 'set local role authenticated';
    perform public.record_attendance(v_member, current_date);
    execute 'reset role';
    v_message := 'recorded';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  select count(*) into v_count
  from public.attendance a
  join p1_28_context ctx on ctx.member_id = a.member_id;

  insert into p1_28_results
  values (
    'attendance still records after rollback and reapply',
    case
      when v_message = 'recorded'
       and v_count = 2
      then 'PASS' else 'FAIL'
    end,
    coalesce(v_message, '') || ' rows ' || coalesce(v_count::text, 'null')
  );
end;
$$;

select test_name, status, detail
from p1_28_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_28_results where status <> 'PASS') then
    raise exception 'p1_28 tests failed';
  end if;
end;
$$;

rollback;
