-- P1-14C expired Pro access enforcement rollback tests.
-- Safe to paste into SQL Editor after applying:
--   1. billing.sql
--   2. member_restore.sql
--   3. p1_14c_expired_pro_access_enforcement.sql
--
-- This test never calls Toss or Edge Functions. It inserts only synthetic data
-- inside this transaction and rolls everything back.

begin;

set local timezone to 'UTC';

create temp table p1_14c_test_results (
  test_name text not null,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_14c_context (
  expired_active_gym_id uuid not null,
  expired_active_user_id uuid not null,
  active_unexpired_gym_id uuid not null,
  active_unexpired_user_id uuid not null,
  canceled_paid_gym_id uuid not null,
  canceled_paid_user_id uuid not null,
  expired_canceled_gym_id uuid not null,
  expired_canceled_user_id uuid not null,
  free_gym_id uuid not null,
  free_user_id uuid not null,
  past_period_end timestamptz not null,
  future_period_end timestamptz not null
) on commit drop;

insert into p1_14c_context
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
  now() - interval '2 days',
  now() + interval '30 days'
);

insert into auth.users (
  id,
  instance_id,
  aud,
  role,
  email,
  encrypted_password,
  email_confirmed_at,
  created_at,
  updated_at,
  raw_app_meta_data,
  raw_user_meta_data
)
select
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  email,
  '',
  now(),
  now(),
  now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_14c_context ctx
cross join lateral (
  values
    (ctx.expired_active_user_id, 'p1_14c_expired_active@example.invalid'),
    (ctx.active_unexpired_user_id, 'p1_14c_active_unexpired@example.invalid'),
    (ctx.canceled_paid_user_id, 'p1_14c_canceled_paid@example.invalid'),
    (ctx.expired_canceled_user_id, 'p1_14c_expired_canceled@example.invalid'),
    (ctx.free_user_id, 'p1_14c_free@example.invalid')
) as users_to_insert(user_id, email);

insert into public.gyms (
  id,
  name,
  owner_name,
  phone,
  plan_code,
  member_limit,
  subscription_status,
  trial_ends_at,
  current_period_end,
  billing_provider,
  billing_customer_id,
  billing_subscription_id,
  auto_renew
)
select gym_id, name, 'P1-14C Owner', '010-0000-0000', plan_code, member_limit,
       subscription_status, now() - interval '30 days', current_period_end,
       billing_provider, billing_customer_id, billing_subscription_id, auto_renew
from p1_14c_context ctx
cross join lateral (
  values
    (ctx.expired_active_gym_id, 'P1-14C Expired Active Pro Gym', 'pro', -1, 'active', ctx.future_period_end, 'toss', 'p1_14c_customer_expired_active', 'p1_14c_billing_expired_active', true),
    (ctx.active_unexpired_gym_id, 'P1-14C Active Unexpired Pro Gym', 'pro', -1, 'active', ctx.future_period_end, 'toss', 'p1_14c_customer_active', 'p1_14c_billing_active', true),
    (ctx.canceled_paid_gym_id, 'P1-14C Canceled Paid Through Gym', 'pro', -1, 'canceled', ctx.future_period_end, 'toss', 'p1_14c_customer_canceled_paid', 'p1_14c_billing_canceled_paid', false),
    (ctx.expired_canceled_gym_id, 'P1-14C Expired Canceled Gym', 'pro', -1, 'canceled', ctx.past_period_end, 'toss', 'p1_14c_customer_expired_canceled', 'p1_14c_billing_expired_canceled', false),
    (ctx.free_gym_id, 'P1-14C Free Gym', 'free', 20, 'expired', null::timestamptz, null::text, null::text, null::text, false)
) as gyms_to_insert(gym_id, name, plan_code, member_limit, subscription_status, current_period_end, billing_provider, billing_customer_id, billing_subscription_id, auto_renew);

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-14C Test User'
from p1_14c_context ctx
cross join lateral (
  values
    (ctx.expired_active_user_id, ctx.expired_active_gym_id),
    (ctx.active_unexpired_user_id, ctx.active_unexpired_gym_id),
    (ctx.canceled_paid_user_id, ctx.canceled_paid_gym_id),
    (ctx.expired_canceled_user_id, ctx.expired_canceled_gym_id),
    (ctx.free_user_id, ctx.free_gym_id)
) as profiles_to_insert(user_id, gym_id)
on conflict (id) do update
set
  gym_id = excluded.gym_id,
  name = excluded.name;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.expired_active_gym_id, 'Expired Active Existing ' || gs, current_date, current_date + 30
from p1_14c_context ctx
cross join generate_series(1, 20) as gs;

select set_config('app.allow_billing_update', '1', true);

update public.gyms g
set current_period_end = ctx.past_period_end,
    updated_at = now()
from p1_14c_context ctx
where g.id = ctx.expired_active_gym_id;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.active_unexpired_gym_id, 'Active Pro Existing ' || gs, current_date, current_date + 30
from p1_14c_context ctx
cross join generate_series(1, 25) as gs;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.canceled_paid_gym_id, 'Canceled Paid Existing ' || gs, current_date, current_date + 30
from p1_14c_context ctx
cross join generate_series(1, 25) as gs;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.expired_canceled_gym_id, 'Expired Canceled Existing ' || gs, current_date, current_date + 30
from p1_14c_context ctx
cross join generate_series(1, 20) as gs;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_gym_id, 'Free Existing ' || gs, current_date, current_date + 30
from p1_14c_context ctx
cross join generate_series(1, 19) as gs;

insert into p1_14c_test_results
select
  'TEST 1: expired active Pro has no Pro access',
  case
    when public.gym_has_pro_access(g) = false
     and public.gym_effective_member_limit(g.id) = 20
    then 'PASS' else 'FAIL'
  end,
  jsonb_build_object(
    'has_pro', public.gym_has_pro_access(g),
    'limit', public.gym_effective_member_limit(g.id),
    'status', g.subscription_status,
    'current_period_end', g.current_period_end
  )::text
from p1_14c_context ctx
join public.gyms g on g.id = ctx.expired_active_gym_id;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select expired_active_gym_id, 'Expired Active Rejected Member', current_date, current_date + 30
    from p1_14c_context;

    insert into p1_14c_test_results
    values ('TEST 2: expired active Pro enforces 20-member limit', 'FAIL', 'insert unexpectedly succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_14c_context ctx on ctx.expired_active_gym_id = m.gym_id;

    insert into p1_14c_test_results
    values (
      'TEST 2: expired active Pro enforces 20-member limit',
      case when v_detail like 'MEMBER_LIMIT_REACHED:%' and v_count = 20 then 'PASS' else 'FAIL' end,
      'error=' || v_detail || ', existing_member_count=' || v_count
    );
  end;
end;
$$;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.active_unexpired_gym_id, 'Active Pro Additional Member', current_date, current_date + 30
from p1_14c_context ctx;

insert into p1_14c_test_results
select
  'TEST 3: active unexpired Pro remains unlimited',
  case
    when public.gym_has_pro_access(g) = true
     and public.gym_effective_member_limit(g.id) = -1
     and count(m.id) = 26
    then 'PASS' else 'FAIL'
  end,
  jsonb_build_object(
    'has_pro', public.gym_has_pro_access(g),
    'limit', public.gym_effective_member_limit(g.id),
    'member_count', count(m.id)
  )::text
from p1_14c_context ctx
join public.gyms g on g.id = ctx.active_unexpired_gym_id
left join public.members m on m.gym_id = g.id
group by g.id, g, ctx.active_unexpired_gym_id;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.canceled_paid_gym_id, 'Canceled Paid Additional Member', current_date, current_date + 30
from p1_14c_context ctx;

insert into p1_14c_test_results
select
  'TEST 4: canceled paid-through Pro keeps access',
  case
    when public.gym_has_pro_access(g) = true
     and public.gym_effective_member_limit(g.id) = -1
     and count(m.id) = 26
    then 'PASS' else 'FAIL'
  end,
  jsonb_build_object(
    'has_pro', public.gym_has_pro_access(g),
    'limit', public.gym_effective_member_limit(g.id),
    'member_count', count(m.id)
  )::text
from p1_14c_context ctx
join public.gyms g on g.id = ctx.canceled_paid_gym_id
left join public.members m on m.gym_id = g.id
group by g.id, g, ctx.canceled_paid_gym_id;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select expired_canceled_gym_id, 'Expired Canceled Rejected Member', current_date, current_date + 30
    from p1_14c_context;

    insert into p1_14c_test_results
    values ('TEST 5: expired canceled Pro uses Free limits', 'FAIL', 'insert unexpectedly succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_14c_context ctx on ctx.expired_canceled_gym_id = m.gym_id;

    insert into p1_14c_test_results
    values (
      'TEST 5: expired canceled Pro uses Free limits',
      case when v_detail like 'MEMBER_LIMIT_REACHED:%'
             and v_count = 20
             and exists (
               select 1
               from public.gyms g
               join p1_14c_context ctx on ctx.expired_canceled_gym_id = g.id
               where public.gym_has_pro_access(g) = false
                 and public.gym_effective_member_limit(g.id) = 20
             )
           then 'PASS' else 'FAIL' end,
      'error=' || v_detail || ', existing_member_count=' || v_count
    );
  end;
end;
$$;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.free_gym_id, 'Free 20th Member', current_date, current_date + 30
from p1_14c_context ctx;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select free_gym_id, 'Free 21st Rejected Member', current_date, current_date + 30
    from p1_14c_context;

    insert into p1_14c_test_results
    values ('TEST 6: Free gym allows 20th and rejects 21st member', 'FAIL', '21st insert unexpectedly succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_14c_context ctx on ctx.free_gym_id = m.gym_id;

    insert into p1_14c_test_results
    values (
      'TEST 6: Free gym allows 20th and rejects 21st member',
      case when v_detail like 'MEMBER_LIMIT_REACHED:%' and v_count = 20 then 'PASS' else 'FAIL' end,
      'error=' || v_detail || ', member_count=' || v_count
    );
  end;
end;
$$;

do $$
declare
  v_detail text;
  v_count integer;
begin
  perform set_config(
    'request.jwt.claim.sub',
    (select expired_active_user_id::text from p1_14c_context),
    true
  );

  begin
    perform public.restore_gym_members_from_json(
      (
        select jsonb_agg(
          jsonb_build_object(
            'name', 'Restore Member ' || gs,
            'phone', '',
            'address', '',
            'startDate', current_date::text,
            'expireDate', (current_date + 30)::text,
            'ptTotal', 0,
            'ptRemaining', 0,
            'memo', '',
            'attendance', '[]'::jsonb
          )
        )
        from generate_series(1, 21) as gs
      )
    );

    insert into p1_14c_test_results
    values ('TEST 7: JSON restore cannot bypass expired Pro limit', 'FAIL', 'restore unexpectedly succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_14c_context ctx on ctx.expired_active_gym_id = m.gym_id;

    insert into p1_14c_test_results
    values (
      'TEST 7: JSON restore cannot bypass expired Pro limit',
      case when v_detail like 'MEMBER_LIMIT_REACHED:%' and v_count = 20 then 'PASS' else 'FAIL' end,
      'error=' || v_detail || ', preserved_member_count=' || v_count
    );
  end;
end;
$$;

create temp table p1_14c_summary_result on commit drop as
select public.get_billing_summary() as summary
from (
  select set_config(
    'request.jwt.claim.sub',
    (select expired_active_user_id::text from p1_14c_context),
    true
  )
) s;

insert into p1_14c_test_results
select
  'TEST 8: billing summary reflects expired active Pro as Free-limited',
  case
    when summary->>'has_pro' = 'false'
     and summary->>'member_limit' = '20'
     and summary->>'can_add_member' = 'false'
     and summary->>'member_count' = '20'
    then 'PASS' else 'FAIL'
  end,
  summary::text
from p1_14c_summary_result;

select *
from p1_14c_test_results
order by test_name;

select
  case
    when not exists (select 1 from p1_14c_test_results where status <> 'PASS') then 1
    else 1 / (
      select count(*)
      from p1_14c_test_results
      where status <> 'PASS'
        and false
    )
  end as p1_14c_assert_all_tests_passed;

rollback;
