-- Synthetic free-member promo checks. This script rolls back.
-- Gym ids are generated here. No production gym is read or written.
-- No payment provider is called.

begin;

set local timezone to 'UTC';

create temp table p1_26_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create or replace function public.p1_26_pin_member_limit_clock(p_at timestamptz)
returns void
language plpgsql
as $$
begin
  execute 'create or replace function public.member_limit_now() returns timestamptz language sql stable as $body$ select '
    || quote_literal(p_at)
    || '::timestamptz $body$';
end;
$$;

revoke all on function public.p1_26_pin_member_limit_clock(timestamptz) from public;

create temp table p1_26_context (
  free_during_gym_id uuid not null,
  free_during_user_id uuid not null,
  free_after_gym_id uuid not null,
  pro_gym_id uuid not null,
  comp_gym_id uuid not null,
  trial_gym_id uuid not null,
  canceled_gym_id uuid not null,
  restore_during_gym_id uuid not null,
  restore_during_user_id uuid not null,
  restore_after_gym_id uuid not null,
  restore_after_user_id uuid not null
) on commit drop;

insert into p1_26_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid()
);

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select user_id, '00000000-0000-0000-0000-000000000000'::uuid, 'authenticated', 'authenticated',
       email, '', now(), now(), now(),
       '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb
from p1_26_context ctx
cross join lateral (
  values
    (ctx.free_during_user_id, 'p1_26_free_during@example.invalid'),
    (ctx.restore_during_user_id, 'p1_26_restore_during@example.invalid'),
    (ctx.restore_after_user_id, 'p1_26_restore_after@example.invalid')
) as users_to_insert(user_id, email);

insert into public.gyms (
  id, name, owner_name, phone, plan_code, member_limit, subscription_status,
  trial_ends_at, current_period_end, auto_renew, complimentary_pro
)
select gym_id, gym_name, 'Synthetic Owner', '000-000-0000', plan_code, 20,
       subscription_status, trial_ends_at, current_period_end, auto_renew, complimentary_pro
from p1_26_context ctx
cross join lateral (
  values
    (ctx.free_during_gym_id, 'P1-26 Free During', 'free', 'expired', now() - interval '30 days', null::timestamptz, false, false),
    (ctx.free_after_gym_id, 'P1-26 Free After', 'free', 'expired', now() - interval '30 days', null::timestamptz, false, false),
    (ctx.pro_gym_id, 'P1-26 Active Pro', 'pro', 'active', now() - interval '30 days', now() + interval '30 days', true, false),
    (ctx.comp_gym_id, 'P1-26 Complimentary', 'pro', 'active', now() - interval '30 days', now() - interval '2 days', false, true),
    (ctx.trial_gym_id, 'P1-26 Trial', 'pro', 'trialing', now() + interval '14 days', null::timestamptz, false, false),
    (ctx.canceled_gym_id, 'P1-26 Canceled Paid Through', 'pro', 'canceled', now() - interval '30 days', now() + interval '30 days', false, false),
    (ctx.restore_during_gym_id, 'P1-26 Restore During', 'free', 'expired', now() - interval '30 days', null::timestamptz, false, false),
    (ctx.restore_after_gym_id, 'P1-26 Restore After', 'free', 'expired', now() - interval '30 days', null::timestamptz, false, false)
) as gyms_to_insert(gym_id, gym_name, plan_code, subscription_status, trial_ends_at, current_period_end, auto_renew, complimentary_pro);

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'Synthetic Owner'
from p1_26_context ctx
cross join lateral (
  values
    (ctx.free_during_user_id, ctx.free_during_gym_id),
    (ctx.restore_during_user_id, ctx.restore_during_gym_id),
    (ctx.restore_after_user_id, ctx.restore_after_gym_id)
) as profiles_to_insert(user_id, gym_id)
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

insert into p1_26_results (test_name, status, detail)
select
  'cutoff instant is 2027-01-01 00:00 KST',
  case
    when public.free_member_promo_ends_at() = timestamptz '2027-01-01 00:00:00+09'
     and timestamptz '2026-12-31 23:59:59+09' = timestamptz '2026-12-31 14:59:59+00'
     and timestamptz '2027-01-01 00:00:00+09' = timestamptz '2026-12-31 15:00:00+00'
     and timestamptz '2026-12-31 23:59:59.999999+09' < public.free_member_promo_ends_at()
     and not (timestamptz '2027-01-01 00:00:00+09' < public.free_member_promo_ends_at())
    then 'PASS' else 'FAIL'
  end,
  public.free_member_promo_ends_at()::text;

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into p1_26_results (test_name, status, detail)
select
  '23:59:59 KST is unlimited for a free gym and a missing gym stays 0',
  case
    when public.member_limit_now() = timestamptz '2026-12-31 23:59:59+09'
     and public.gym_effective_member_limit(ctx.free_during_gym_id) = -1
     and public.gym_has_pro_access(g) = false
     and g.member_limit = 20
     and public.gym_effective_member_limit(gen_random_uuid()) = 0
    then 'PASS' else 'FAIL'
  end,
  public.gym_effective_member_limit(ctx.free_during_gym_id)::text
from p1_26_context ctx
join public.gyms g on g.id = ctx.free_during_gym_id;

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59.999999+09');

insert into p1_26_results (test_name, status, detail)
select
  'last microsecond of 2026-12-31 KST stays unlimited',
  case
    when public.gym_effective_member_limit(ctx.free_during_gym_id) = -1
    then 'PASS' else 'FAIL'
  end,
  public.member_limit_now()::text
from p1_26_context ctx;

set local timezone to 'America/New_York';
select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into p1_26_results (test_name, status, detail)
select
  'New York timezone still treats 23:59:59 KST as unlimited',
  case
    when public.gym_effective_member_limit(ctx.free_during_gym_id) = -1
     and public.member_limit_now() = timestamptz '2026-12-31 23:59:59+09'
    then 'PASS' else 'FAIL'
  end,
  public.member_limit_now()::text
from p1_26_context ctx;

set local timezone to 'Asia/Seoul';
select public.p1_26_pin_member_limit_clock(timestamptz '2027-01-01 00:00:00+09');

insert into p1_26_results (test_name, status, detail)
select
  '00:00 KST restores the free cap of 20 in Seoul timezone',
  case
    when public.member_limit_now() = timestamptz '2027-01-01 00:00:00+09'
     and public.gym_effective_member_limit(ctx.free_after_gym_id) = 20
     and public.gym_has_pro_access(g) = false
    then 'PASS' else 'FAIL'
  end,
  public.gym_effective_member_limit(ctx.free_after_gym_id)::text
from p1_26_context ctx
join public.gyms g on g.id = ctx.free_after_gym_id;

set local timezone to 'UTC';

select public.p1_26_pin_member_limit_clock(timestamptz '2027-01-01 00:00:00+09');

insert into p1_26_results (test_name, status, detail)
select
  'pro trial canceled-through and complimentary stay unlimited after the cutoff',
  case
    when public.gym_effective_member_limit(ctx.pro_gym_id) = -1
     and public.gym_has_pro_access(pro) = true
     and public.gym_effective_member_limit(ctx.trial_gym_id) = -1
     and public.gym_has_pro_access(trial_gym) = true
     and public.gym_effective_member_limit(ctx.canceled_gym_id) = -1
     and public.gym_has_pro_access(canceled) = true
     and public.gym_effective_member_limit(ctx.comp_gym_id) = -1
     and public.gym_has_pro_access(comp) = true
     and comp.member_limit = 20
     and comp.current_period_end < now()
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_26_context ctx
join public.gyms pro on pro.id = ctx.pro_gym_id
join public.gyms trial_gym on trial_gym.id = ctx.trial_gym_id
join public.gyms canceled on canceled.id = ctx.canceled_gym_id
join public.gyms comp on comp.id = ctx.comp_gym_id;

select set_config('app.allow_billing_update', '1', true);

update public.gyms
set member_limit = -1
where id = (select free_after_gym_id from p1_26_context);

insert into p1_26_results (test_name, status, detail)
select
  'stored member_limit -1 does not bypass the free cap after the cutoff',
  case
    when g.member_limit = -1
     and public.gym_effective_member_limit(g.id) = 20
    then 'PASS' else 'FAIL'
  end,
  g.member_limit::text
from public.gyms g
join p1_26_context ctx on ctx.free_after_gym_id = g.id;

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_during_gym_id, 'Free During ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 20) as gs;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_during_gym_id, 'Free During 21', current_date, current_date + 30
from p1_26_context ctx;

insert into p1_26_results (test_name, status, detail)
select
  'free gym accepts member 21 at 2026-12-31 23:59:59 KST while the column stays 20',
  case
    when count(m.id) = 21
     and public.gym_effective_member_limit(g.id) = -1
     and g.member_limit = 20
    then 'PASS' else 'FAIL'
  end,
  count(m.id)::text
from p1_26_context ctx
join public.gyms g on g.id = ctx.free_during_gym_id
left join public.members m on m.gym_id = g.id
group by g.id, g.member_limit;

select public.p1_26_pin_member_limit_clock(timestamptz '2027-01-01 00:00:00+09');

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_after_gym_id, 'Free After ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 20) as gs;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select free_after_gym_id, 'Free After 21', current_date, current_date + 30
    from p1_26_context;

    insert into p1_26_results
    values ('free gym rejects member 21 at 2027-01-01 00:00 KST', 'FAIL', 'insert succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_26_context ctx on ctx.free_after_gym_id = m.gym_id;

    insert into p1_26_results
    values (
      'free gym rejects member 21 at 2027-01-01 00:00 KST',
      case
        when v_detail like 'MEMBER_LIMIT_REACHED:20%' and v_count = 20
        then 'PASS' else 'FAIL'
      end,
      v_detail || ' count=' || v_count
    );
  end;
end;
$$;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.pro_gym_id, 'Pro After ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 21) as gs;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.comp_gym_id, 'Comp After ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 21) as gs;

insert into p1_26_results (test_name, status, detail)
select
  'active pro and complimentary still accept member 21 after the cutoff',
  case
    when (
      select count(*) from public.members m
      join p1_26_context ctx on ctx.pro_gym_id = m.gym_id
    ) = 21
     and (
      select count(*) from public.members m
      join p1_26_context ctx on ctx.comp_gym_id = m.gym_id
    ) = 21
     and public.gym_effective_member_limit(ctx.pro_gym_id) = -1
     and public.gym_effective_member_limit(ctx.comp_gym_id) = -1
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_26_context ctx;

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.restore_during_gym_id, 'Restore During Seed ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 2) as gs;

select set_config(
  'request.jwt.claim.sub',
  (select restore_during_user_id::text from p1_26_context),
  true
);

select public.restore_gym_members_from_json(
  (
    select jsonb_agg(jsonb_build_object(
      'name', 'Restored During ' || gs,
      'phone', '',
      'startDate', current_date::text,
      'expireDate', (current_date + 30)::text,
      'attendance', '[]'::jsonb
    ))
    from generate_series(1, 21) as gs
  )
);

insert into p1_26_results (test_name, status, detail)
select
  'restore of 21 members succeeds during the promo',
  case
    when count(m.id) = 21
     and public.gym_effective_member_limit(ctx.restore_during_gym_id) = -1
    then 'PASS' else 'FAIL'
  end,
  count(m.id)::text
from p1_26_context ctx
left join public.members m on m.gym_id = ctx.restore_during_gym_id
group by ctx.restore_during_gym_id;

select public.p1_26_pin_member_limit_clock(timestamptz '2027-01-01 00:00:00+09');

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.restore_after_gym_id, 'Restore After Seed ' || gs, current_date, current_date + 30
from p1_26_context ctx
cross join generate_series(1, 2) as gs;

do $$
declare
  v_detail text;
  v_count integer;
begin
  perform set_config(
    'request.jwt.claim.sub',
    (select restore_after_user_id::text from p1_26_context),
    true
  );

  begin
    perform public.restore_gym_members_from_json(
      (
        select jsonb_agg(jsonb_build_object(
          'name', 'Restored After ' || gs,
          'phone', '',
          'startDate', current_date::text,
          'expireDate', (current_date + 30)::text,
          'attendance', '[]'::jsonb
        ))
        from generate_series(1, 21) as gs
      )
    );

    insert into p1_26_results
    values ('restore of 21 members is rejected after the cutoff', 'FAIL', 'restore succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_26_context ctx on ctx.restore_after_gym_id = m.gym_id;

    insert into p1_26_results
    values (
      'restore of 21 members is rejected after the cutoff',
      case
        when v_detail like 'MEMBER_LIMIT_REACHED:20%' and v_count = 2
        then 'PASS' else 'FAIL'
      end,
      v_detail || ' count=' || v_count
    );
  end;
end;
$$;

select set_config(
  'request.jwt.claim.sub',
  (select free_during_user_id::text from p1_26_context),
  true
);

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into p1_26_results (test_name, status, detail)
select
  'billing summary is unlimited for a free gym during the promo',
  case
    when summary->>'has_pro' = 'false'
     and summary->>'member_limit' = '-1'
     and summary->>'can_add_member' = 'true'
     and summary->>'member_count' = '21'
     and summary->>'plan_code' = 'free'
    then 'PASS' else 'FAIL'
  end,
  summary::text
from (
  select public.get_billing_summary() as summary
) s;

insert into p1_26_results (test_name, status, detail)
select
  'signup trial length is unchanged',
  case
    when position('14 days' in signup_def) > 0
     and position('free_member_promo' in signup_def) = 0
     and position('member_limit_now' in signup_def) = 0
     and position('toss' in lower(limit_def)) = 0
     and position('activate_gym_pro' in limit_def) = 0
     and position('handle_new_user' in limit_def) = 0
    then 'PASS' else 'FAIL'
  end,
  'compared'
from (
  select pg_get_functiondef('public.handle_new_user()'::regprocedure) as signup_def,
         pg_get_functiondef('public.gym_effective_member_limit(uuid)'::regprocedure) as limit_def
) defs;

insert into p1_26_results (test_name, status, detail)
select
  'effective limit stays security definer and clients cannot execute the clock',
  case
    when prosecdef
     and 'search_path=public' = any(proconfig)
     and has_function_privilege('public', 'public.member_limit_now()', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.member_limit_now()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.member_limit_now()', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.gym_effective_member_limit(uuid)', 'EXECUTE') = true
     and has_function_privilege('authenticated', 'public.free_member_promo_ends_at()', 'EXECUTE') = false
    then 'PASS' else 'FAIL'
  end,
  coalesce(proconfig::text, 'no config')
from pg_proc
where oid = 'public.gym_effective_member_limit(uuid)'::regprocedure;

do $$
declare
  v_message text;
begin
  begin
    execute 'set local role authenticated';
    execute $fn$
      create or replace function public.member_limit_now()
      returns timestamptz
      language sql
      as $body$ select timestamptz '2026-06-01 00:00:00+09' $body$
    $fn$;
    execute 'reset role';
    v_message := 'replaced';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  insert into p1_26_results
  values (
    'authenticated cannot replace the member limit clock',
    case
      when v_message ilike '%permission denied%' or v_message ilike '%must be owner%'
      then 'PASS' else 'FAIL'
    end,
    v_message
  );
end;
$$;

insert into p1_26_results (test_name, status, detail)
select
  'clock is unchanged after the authenticated replace attempt',
  case
    when public.member_limit_now() = timestamptz '2026-12-31 23:59:59+09'
    then 'PASS' else 'FAIL'
  end,
  public.member_limit_now()::text;

\ir p1_26_free_member_cap_promo_rollback.sql

insert into p1_26_results (test_name, status, detail)
select
  'rollback restores the standing cap and drops the promo clock',
  case
    when to_regprocedure('public.member_limit_now()') is null
     and to_regprocedure('public.free_member_promo_ends_at()') is null
     and public.gym_effective_member_limit(ctx.free_during_gym_id) = 20
     and public.gym_effective_member_limit(ctx.pro_gym_id) = -1
     and public.gym_effective_member_limit(ctx.comp_gym_id) = -1
     and public.gym_has_pro_access(pro) = true
    then 'PASS' else 'FAIL'
  end,
  public.gym_effective_member_limit(ctx.free_during_gym_id)::text
from p1_26_context ctx
join public.gyms pro on pro.id = ctx.pro_gym_id;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select free_during_gym_id, 'After Rollback Rejected', current_date, current_date + 30
    from p1_26_context;

    insert into p1_26_results
    values ('rollback rejects another free member once 20 already exist', 'FAIL', 'insert succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_26_context ctx on ctx.free_during_gym_id = m.gym_id;

    insert into p1_26_results
    values (
      'rollback rejects another free member once 20 already exist',
      case
        when v_detail like 'MEMBER_LIMIT_REACHED:20%' and v_count = 21
        then 'PASS' else 'FAIL'
      end,
      v_detail || ' count=' || v_count
    );
  end;
end;
$$;

\ir p1_26_free_member_cap_promo.sql

select public.p1_26_pin_member_limit_clock(timestamptz '2026-12-31 23:59:59+09');

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_during_gym_id, 'Free During 22', current_date, current_date + 30
from p1_26_context ctx;

insert into p1_26_results (test_name, status, detail)
select
  'reapplying the migration lifts the cap again at 23:59:59 KST',
  case
    when to_regprocedure('public.member_limit_now()') is not null
     and public.gym_effective_member_limit(ctx.free_during_gym_id) = -1
     and count(m.id) = 22
    then 'PASS' else 'FAIL'
  end,
  count(m.id)::text
from p1_26_context ctx
left join public.members m on m.gym_id = ctx.free_during_gym_id
group by ctx.free_during_gym_id;

select public.p1_26_pin_member_limit_clock(timestamptz '2027-01-01 00:00:00+09');

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select free_during_gym_id, 'Free During After Reapply Rejected', current_date, current_date + 30
    from p1_26_context;

    insert into p1_26_results
    values ('reapplied migration rejects member inserts after the cutoff', 'FAIL', 'insert succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_26_context ctx on ctx.free_during_gym_id = m.gym_id;

    insert into p1_26_results
    values (
      'reapplied migration rejects member inserts after the cutoff',
      case
        when v_detail like 'MEMBER_LIMIT_REACHED:20%' and v_count = 22
        then 'PASS' else 'FAIL'
      end,
      v_detail || ' count=' || v_count
    );
  end;
end;
$$;

select test_name, status, detail
from p1_26_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_26_results where status <> 'PASS') then
    raise exception 'p1_26 tests failed';
  end if;
end;
$$;

rollback;
