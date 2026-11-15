-- Synthetic free period-extension checks. This script rolls back.
-- Gym ids are generated here. No production gym is read or written.
-- No payment provider is called.

begin;

set local timezone to 'UTC';

create temp table p1_27_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_27_context (
  main_gym_id uuid not null,
  main_user_id uuid not null,
  untouched_gym_id uuid not null,
  wrong_expected_gym_id uuid not null,
  window_gym_id uuid not null,
  not_future_gym_id uuid not null,
  free_gym_id uuid not null,
  complimentary_gym_id uuid not null,
  canceled_gym_id uuid not null,
  in_progress_gym_id uuid not null,
  charge_failed_gym_id uuid not null,
  revert_gym_id uuid not null,
  revert_blocked_gym_id uuid not null,
  past_end timestamptz not null,
  future_end timestamptz not null
) on commit drop;

insert into p1_27_context
select
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(),
  now() - interval '1 day',
  now() + interval '20 days';

alter table auth.users disable trigger on_auth_user_created;

insert into auth.users (
  id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  ctx.main_user_id,
  'authenticated',
  'authenticated',
  'synthetic-extension@example.invalid',
  '',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_27_context ctx;

alter table auth.users enable trigger on_auth_user_created;

insert into public.gyms (
  id, name, owner_name, phone, plan_code, member_limit, subscription_status,
  trial_ends_at, current_period_end, billing_provider, billing_customer_id,
  billing_subscription_id, auto_renew, complimentary_pro
)
select
  gym_id, gym_name, 'Synthetic Owner', '000-000-0000', plan_code, member_limit,
  subscription_status, now() - interval '40 days', current_period_end,
  billing_provider, billing_customer_id, billing_subscription_id, auto_renew,
  complimentary_pro
from p1_27_context ctx
cross join lateral (
  values
    (ctx.main_gym_id, 'Synthetic Paid Gym', 'pro', -1, 'active', ctx.past_end, 'toss', 'synthetic-main-customer', 'synthetic-main-billing-ref', false, false),
    (ctx.untouched_gym_id, 'Synthetic Untouched Gym', 'pro', -1, 'active', ctx.future_end, 'toss', 'synthetic-untouched-customer', 'synthetic-untouched-billing-ref', true, false),
    (ctx.wrong_expected_gym_id, 'Synthetic Wrong Expected Gym', 'pro', -1, 'active', ctx.future_end, null::text, null::text, null::text, false, false),
    (ctx.window_gym_id, 'Synthetic Window Gym', 'pro', -1, 'active', ctx.future_end, 'toss', 'synthetic-window-customer', 'synthetic-window-billing-ref', true, false),
    (ctx.not_future_gym_id, 'Synthetic Not Future Gym', 'pro', -1, 'active', ctx.past_end, null::text, null::text, null::text, false, false),
    (ctx.free_gym_id, 'Synthetic Free Gym', 'free', 20, 'active', ctx.future_end, null::text, null::text, null::text, false, false),
    (ctx.complimentary_gym_id, 'Synthetic Complimentary Gym', 'pro', -1, 'active', ctx.past_end, null::text, null::text, null::text, false, true),
    (ctx.canceled_gym_id, 'Synthetic Canceled Gym', 'pro', -1, 'canceled', ctx.future_end, null::text, null::text, null::text, false, false),
    (ctx.in_progress_gym_id, 'Synthetic In Progress Gym', 'pro', -1, 'active', ctx.future_end, null::text, null::text, null::text, true, false),
    (ctx.charge_failed_gym_id, 'Synthetic Charge Failed Gym', 'pro', -1, 'active', ctx.future_end, null::text, null::text, null::text, false, false),
    (ctx.revert_gym_id, 'Synthetic Revert Gym', 'pro', -1, 'active', ctx.future_end, 'toss', 'synthetic-revert-customer', 'synthetic-revert-billing-ref', false, false),
    (ctx.revert_blocked_gym_id, 'Synthetic Revert Blocked Gym', 'pro', -1, 'active', ctx.future_end, 'toss', 'synthetic-blocked-customer', 'synthetic-blocked-billing-ref', false, false)
) as gyms_to_insert(
  gym_id, gym_name, plan_code, member_limit, subscription_status, current_period_end,
  billing_provider, billing_customer_id, billing_subscription_id, auto_renew, complimentary_pro
);

insert into public.profiles (id, gym_id, name)
select ctx.main_user_id, ctx.main_gym_id, 'Synthetic User'
from p1_27_context ctx;

insert into private.billing_credentials (gym_id, provider, billing_key)
select ctx.main_gym_id, 'toss', 'synthetic-billing-key'
from p1_27_context ctx;

insert into public.payment_attempts (
  gym_id, provider, payment_type, billing_interval, amount_krw, currency,
  order_id, target_period_start, target_period_end, status, activation_status,
  recovery_status, activated_at, created_at, provider_response
)
select
  ctx.main_gym_id,
  'toss',
  'auto_renewal',
  'monthly',
  10000,
  'KRW',
  'synthetic-extension-prior-order',
  ctx.past_end - interval '30 days',
  ctx.past_end,
  'completed',
  'succeeded',
  'none',
  ctx.past_end - interval '30 days',
  ctx.past_end - interval '30 days',
  '{}'::jsonb
from p1_27_context ctx;

create temp table p1_27_gym_before on commit drop as
select * from public.gyms;

create temp table p1_27_attempt_before on commit drop as
select * from public.payment_attempts;

create temp table p1_27_credential_before on commit drop as
select * from private.billing_credentials;

insert into p1_27_results (test_name, status, detail)
select
  'pro access is false while the paid period is already over',
  case
    when public.gym_has_pro_access(g) = false
     and g.current_period_end = ctx.past_end
     and g.current_period_end <= now()
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_context ctx
join public.gyms g on g.id = ctx.main_gym_id;

create temp table p1_27_main_extend on commit drop as
select public.extend_gym_period_free(
  ctx.main_gym_id,
  ctx.past_end,
  ctx.past_end + interval '30 days',
  'synthetic free extension'
) as result
from p1_27_context ctx;

insert into p1_27_results (test_name, status, detail)
select
  'extend changes only the period end and writes one zero-amount history row',
  case
    when extended.result->>'noop' = 'false'
     and (extended.result->>'history_count')::integer = 1
     and (extended.result->>'before_end')::timestamptz = before.current_period_end
     and (extended.result->>'after_end')::timestamptz = before.current_period_end + interval '30 days'
     and g.current_period_end = before.current_period_end + interval '30 days'
     and (to_jsonb(g) - 'current_period_end') = (to_jsonb(before) - 'current_period_end')
     and g.plan_code = before.plan_code
     and g.subscription_status = before.subscription_status
     and g.auto_renew = before.auto_renew
     and g.complimentary_pro = before.complimentary_pro
     and g.member_limit = before.member_limit
     and g.billing_provider is not distinct from before.billing_provider
     and g.billing_customer_id is not distinct from before.billing_customer_id
     and g.billing_subscription_id is not distinct from before.billing_subscription_id
     and g.updated_at is not distinct from before.updated_at
     and (
       select count(*)
       from public.subscriptions s
       where s.gym_id = g.id
         and s.amount_krw = 0
         and s.provider = 'manual'
         and s.provider_ref is null
         and s.plan_code = 'pro'
         and s.status = 'active'
         and s.started_at = before.current_period_end
         and s.ends_at = g.current_period_end
         and s.raw->>'reason' = 'free_period_extension'
         and s.raw->>'note' = 'synthetic free extension'
         and (s.raw->>'previous_period_end')::timestamptz = before.current_period_end
         and (s.raw->>'new_period_end')::timestamptz = g.current_period_end
     ) = 1
     and (
       select count(*)
       from public.payment_attempts pa
       where pa.gym_id = g.id
     ) = 1
     and not exists (
       select 1
       from public.payment_attempts pa
       where pa.gym_id = g.id
         and pa.amount_krw = 0
     )
     and not exists (
       select 1
       from public.gyms other
       join p1_27_gym_before other_before on other_before.id = other.id
       where other.id <> g.id
         and to_jsonb(other) is distinct from to_jsonb(other_before)
     )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_main_extend extended
join p1_27_context ctx on true
join public.gyms g on g.id = ctx.main_gym_id
join p1_27_gym_before before on before.id = g.id;

insert into p1_27_results (test_name, status, detail)
select
  'pro access is true once the extended end is still ahead',
  case
    when public.gym_has_pro_access(g) = true
     and g.current_period_end > now()
     and g.current_period_end > ctx.past_end
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_context ctx
join public.gyms g on g.id = ctx.main_gym_id;

create temp table p1_27_main_after_extend on commit drop as
select * from public.gyms where id = (select main_gym_id from p1_27_context);

do $$
declare
  v_result jsonb;
  v_message text;
  v_main_id uuid;
  v_past_end timestamptz;
begin
  select main_gym_id, past_end into v_main_id, v_past_end from p1_27_context;
  begin
    execute 'set local role service_role';
    v_result := public.extend_gym_period_free(
      v_main_id,
      v_past_end,
      v_past_end + interval '30 days',
      'synthetic free extension'
    );
    execute 'reset role';
    v_message := 'ok';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
    v_result := null;
  end;

  insert into p1_27_results
  values (
    'second identical call is a no-op and keeps one history row',
    case
      when v_message = 'ok'
       and v_result->>'noop' = 'true'
       and (v_result->>'history_count')::integer = 1
       and (v_result->>'before_end')::timestamptz = v_past_end
       and (v_result->>'after_end')::timestamptz = v_past_end + interval '30 days'
       and (
         select count(*)
         from public.subscriptions s
         where s.gym_id = v_main_id
           and s.raw->>'reason' = 'free_period_extension'
       ) = 1
       and exists (
         select 1
         from public.gyms g
         join p1_27_main_after_extend snap on snap.id = g.id
         where to_jsonb(g) = to_jsonb(snap)
       )
      then 'PASS' else 'FAIL'
    end,
    coalesce(v_message, 'missing')
  );
end;
$$;

do $$
declare
  v_message text;
  v_main_id uuid;
  v_past_end timestamptz;
begin
  select main_gym_id, past_end into v_main_id, v_past_end from p1_27_context;
  begin
    perform public.extend_gym_period_free(
      v_main_id,
      v_past_end,
      v_past_end + interval '40 days',
      'synthetic free extension'
    );
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  insert into p1_27_results
  values (
    'a different new end after the move fails and does not add a row',
    case
      when v_message = 'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END'
       and (
         select count(*)
         from public.subscriptions s
         where s.gym_id = v_main_id
           and s.raw->>'reason' = 'free_period_extension'
       ) = 1
       and exists (
         select 1
         from public.gyms g
         join p1_27_main_after_extend snap on snap.id = g.id
         where to_jsonb(g) = to_jsonb(snap)
       )
      then 'PASS' else 'FAIL'
    end,
    v_message
  );
end;
$$;

create temp table p1_27_reconcile_auto on commit drop as
select *
from public.claim_stale_auto_renewal_reconciliation_attempts(now(), 50);

create temp table p1_27_reconcile_initial on commit drop as
select *
from public.claim_stale_initial_billing_reconciliation_attempts(now(), 50);

insert into p1_27_results (test_name, status, detail)
select
  'reconciliation ignores the zero-amount extension row',
  case
    when not exists (
      select 1 from p1_27_reconcile_auto claim
      where claim.gym_id = ctx.main_gym_id
    )
     and not exists (
      select 1 from p1_27_reconcile_initial claim
      where claim.gym_id = ctx.main_gym_id
    )
     and not exists (
      select 1
      from public.payment_attempts pa
      join p1_27_attempt_before before on before.id = pa.id
      where to_jsonb(pa) is distinct from to_jsonb(before)
    )
     and (
       select count(*)
       from public.subscriptions s
       where s.gym_id = ctx.main_gym_id
         and s.amount_krw = 0
         and s.provider = 'manual'
         and s.provider_ref is null
         and s.raw->>'reason' = 'free_period_extension'
     ) = 1
     and position(
       'free_period_extension' in pg_get_functiondef(
         'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)'::regprocedure
       )
     ) = 0
     and position(
       'free_period_extension' in pg_get_functiondef(
         'public.claim_stale_initial_billing_reconciliation_attempts(timestamptz, integer)'::regprocedure
       )
     ) = 0
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_context ctx;

do $$
declare
  v_zero integer;
  v_paid integer;
begin
  perform set_config('request.jwt.claim.sub', (select main_user_id::text from p1_27_context), true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  select
    count(*) filter (where amount_krw = 0),
    count(*) filter (where amount_krw = 10000)
  into v_zero, v_paid
  from public.get_payment_history();

  perform set_config('request.jwt.claim.sub', '', true);
  perform set_config('request.jwt.claim.role', '', true);

  insert into p1_27_results
  values (
    'payment history shows the prior charge and not the zero-amount extension',
    case when v_zero = 0 and v_paid = 1 then 'PASS' else 'FAIL' end,
    'zero=' || v_zero || ' paid=' || v_paid
  );
end;
$$;

insert into public.payment_attempts (
  gym_id, provider, payment_type, billing_interval, amount_krw, currency,
  order_id, target_period_start, target_period_end, status, activation_status,
  recovery_status, provider_response
)
select
  gym_id, 'toss', 'auto_renewal', 'monthly', 10000, 'KRW',
  order_id, ctx.future_end - interval '30 days', ctx.future_end,
  attempt_status, activation_status, recovery_status, '{}'::jsonb
from p1_27_context ctx
cross join lateral (
  values
    (ctx.in_progress_gym_id, 'synthetic-extension-open-order', 'initiated', 'not_started', 'none'),
    (ctx.charge_failed_gym_id, 'synthetic-extension-failed-order', 'charge_failed', 'not_started', 'none')
) as attempts(gym_id, order_id, attempt_status, activation_status, recovery_status);

do $$
declare
  r record;
  v_message text;
  v_before jsonb;
  v_after jsonb;
  v_history integer;
begin
  for r in
    select *
    from (
      select
        'wrong expected end fails'::text as test_name,
        ctx.wrong_expected_gym_id as gym_id,
        ctx.future_end + interval '1 day' as expected_end,
        ctx.future_end + interval '5 days' as new_end,
        'synthetic reason'::text as reason,
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:EXPECTED_END'::text as error_like
      from p1_27_context ctx
      union all
      select
        'more than 90 days fails',
        ctx.window_gym_id,
        ctx.future_end,
        ctx.future_end + interval '90 days' + interval '1 second',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:WINDOW'
      from p1_27_context ctx
      union all
      select
        'an end that is not later fails',
        ctx.window_gym_id,
        ctx.future_end,
        ctx.future_end,
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:NOT_LATER'
      from p1_27_context ctx
      union all
      select
        'an end that is not in the future fails',
        ctx.not_future_gym_id,
        ctx.past_end,
        now(),
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:NOT_FUTURE'
      from p1_27_context ctx
      union all
      select
        'a non-pro gym fails',
        ctx.free_gym_id,
        ctx.future_end,
        ctx.future_end + interval '10 days',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:PLAN'
      from p1_27_context ctx
      union all
      select
        'a complimentary gym fails',
        ctx.complimentary_gym_id,
        ctx.past_end,
        ctx.past_end + interval '10 days',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:COMPLIMENTARY'
      from p1_27_context ctx
      union all
      select
        'a non-active gym fails',
        ctx.canceled_gym_id,
        ctx.future_end,
        ctx.future_end + interval '10 days',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:STATUS'
      from p1_27_context ctx
      union all
      select
        'an in-progress attempt fails',
        ctx.in_progress_gym_id,
        ctx.future_end,
        ctx.future_end + interval '10 days',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_PRECONDITION_FAILED:ATTEMPT_IN_PROGRESS'
      from p1_27_context ctx
      union all
      select
        'a missing gym fails',
        gen_random_uuid(),
        ctx.future_end,
        ctx.future_end + interval '10 days',
        'synthetic reason',
        'GYM_PERIOD_EXTENSION_TARGET_COUNT'
      from p1_27_context ctx
      union all
      select
        'an empty reason fails',
        ctx.untouched_gym_id,
        ctx.future_end,
        ctx.future_end + interval '10 days',
        '   ',
        'GYM_PERIOD_EXTENSION_REASON_REQUIRED'
      from p1_27_context ctx
    ) as cases
  loop
    select to_jsonb(g) into v_before
    from public.gyms g
    where g.id = r.gym_id;

    begin
      perform public.extend_gym_period_free(
        r.gym_id,
        r.expected_end,
        r.new_end,
        r.reason
      );
      v_message := 'call returned';
    exception when others then
      v_message := sqlerrm;
    end;

    select to_jsonb(g) into v_after
    from public.gyms g
    where g.id = r.gym_id;

    select count(*) into v_history
    from public.subscriptions s
    where s.gym_id = r.gym_id
      and s.raw->>'reason' = 'free_period_extension';

    insert into p1_27_results
    values (
      r.test_name,
      case
        when v_message = r.error_like
         and v_after is not distinct from v_before
         and v_history = 0
        then 'PASS' else 'FAIL'
      end,
      v_message
    );
  end loop;
end;
$$;

create temp table p1_27_charge_failed_before on commit drop as
select * from public.gyms g
where g.id = (select charge_failed_gym_id from p1_27_context);

create temp table p1_27_charge_failed_extend on commit drop as
select public.extend_gym_period_free(
  ctx.charge_failed_gym_id,
  ctx.future_end,
  ctx.future_end + interval '15 days',
  'synthetic failed-attempt extension'
) as result
from p1_27_context ctx;

insert into p1_27_results (test_name, status, detail)
select
  'a closed failed attempt does not block the extension',
  case
    when extended.result->>'noop' = 'false'
     and (extended.result->>'history_count')::integer = 1
     and g.current_period_end = before.current_period_end + interval '15 days'
     and (to_jsonb(g) - 'current_period_end') = (to_jsonb(before) - 'current_period_end')
     and exists (
       select 1
       from public.payment_attempts pa
       where pa.gym_id = g.id
         and pa.status = 'charge_failed'
         and pa.recovery_status = 'none'
         and pa.amount_krw = 10000
     )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_charge_failed_extend extended
join p1_27_context ctx on true
join public.gyms g on g.id = ctx.charge_failed_gym_id
join p1_27_charge_failed_before before on before.id = g.id;

create temp table p1_27_window_before on commit drop as
select * from public.gyms g
where g.id = (select window_gym_id from p1_27_context);

create temp table p1_27_window_extend on commit drop as
select public.extend_gym_period_free(
  ctx.window_gym_id,
  ctx.future_end,
  ctx.future_end + interval '90 days',
  'synthetic ninety day extension'
) as result
from p1_27_context ctx;

insert into p1_27_results (test_name, status, detail)
select
  'an extension of exactly 90 days succeeds and leaves auto renew unchanged',
  case
    when extended.result->>'noop' = 'false'
     and g.current_period_end = before.current_period_end + interval '90 days'
     and g.auto_renew = true
     and before.auto_renew = true
     and (to_jsonb(g) - 'current_period_end') = (to_jsonb(before) - 'current_period_end')
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_window_extend extended
join p1_27_context ctx on true
join public.gyms g on g.id = ctx.window_gym_id
join p1_27_window_before before on before.id = g.id;

create temp table p1_27_revert_before on commit drop as
select * from public.gyms g
where g.id = (select revert_gym_id from p1_27_context);

create temp table p1_27_revert_extend on commit drop as
select public.extend_gym_period_free(
  ctx.revert_gym_id,
  ctx.future_end,
  ctx.future_end + interval '10 days',
  'synthetic revert extension'
) as result
from p1_27_context ctx;

create temp table p1_27_revert_call on commit drop as
select public.revert_gym_period_free_extension(
  ctx.revert_gym_id,
  ctx.future_end + interval '10 days'
) as result
from p1_27_context ctx;

insert into p1_27_results (test_name, status, detail)
select
  'revert restores the previous end and deletes the history row',
  case
    when extended.result->>'noop' = 'false'
     and reverted.result->>'noop' = 'false'
     and (reverted.result->>'before_end')::timestamptz = ctx.future_end + interval '10 days'
     and (reverted.result->>'after_end')::timestamptz = ctx.future_end
     and (reverted.result->>'history_count')::integer = 0
     and to_jsonb(g) = to_jsonb(before)
     and not exists (
       select 1
       from public.subscriptions s
       where s.gym_id = g.id
         and s.raw->>'reason' = 'free_period_extension'
     )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_revert_extend extended
join p1_27_revert_call reverted on true
join p1_27_context ctx on true
join public.gyms g on g.id = ctx.revert_gym_id
join p1_27_revert_before before on before.id = g.id;

create temp table p1_27_blocked_extend on commit drop as
select public.extend_gym_period_free(
  ctx.revert_blocked_gym_id,
  ctx.future_end,
  ctx.future_end + interval '12 days',
  'synthetic blocked extension'
) as result
from p1_27_context ctx;

insert into public.payment_attempts (
  gym_id, provider, payment_type, billing_interval, amount_krw, currency,
  order_id, target_period_start, target_period_end, status, activation_status,
  recovery_status, activated_at, created_at, provider_response
)
select
  ctx.revert_blocked_gym_id,
  'toss',
  'auto_renewal',
  'monthly',
  10000,
  'KRW',
  'synthetic-extension-later-order',
  now(),
  now() + interval '30 days',
  'completed',
  'succeeded',
  'none',
  now() + interval '1 minute',
  now() + interval '1 minute',
  '{}'::jsonb
from p1_27_context ctx;

create temp table p1_27_blocked_before_revert on commit drop as
select * from public.gyms g
where g.id = (select revert_blocked_gym_id from p1_27_context);

do $$
declare
  v_message text;
  v_gym_id uuid;
  v_extended timestamptz;
begin
  select revert_blocked_gym_id, future_end + interval '12 days'
  into v_gym_id, v_extended
  from p1_27_context;

  begin
    perform public.revert_gym_period_free_extension(v_gym_id, v_extended);
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  insert into p1_27_results
  values (
    'revert refuses after a later successful payment',
    case
      when v_message = 'GYM_PERIOD_EXTENSION_REVERT_BLOCKED:LATER_PAYMENT'
       and exists (
         select 1
         from public.gyms g
         join p1_27_blocked_before_revert snap on snap.id = g.id
         where to_jsonb(g) = to_jsonb(snap)
           and g.current_period_end = v_extended
       )
       and (
         select count(*)
         from public.subscriptions s
         where s.gym_id = v_gym_id
           and s.amount_krw = 0
           and s.raw->>'reason' = 'free_period_extension'
       ) = 1
      then 'PASS' else 'FAIL'
    end,
    v_message
  );
end;
$$;

insert into p1_27_results (test_name, status, detail)
select
  'extension functions do not read billing credential columns',
  case
    when position('billing_key' in extend_def) = 0
     and position('billing_customer' in extend_def) = 0
     and position('billing_subscription' in extend_def) = 0
     and position('customer_key' in extend_def) = 0
     and position('billing_credentials' in extend_def) = 0
     and position('billing_key' in revert_def) = 0
     and position('billing_customer' in revert_def) = 0
     and position('billing_subscription' in revert_def) = 0
     and position('customer_key' in revert_def) = 0
     and position('billing_credentials' in revert_def) = 0
     and exists (
       select 1
       from private.billing_credentials c
       join p1_27_credential_before before on before.id = c.id
       where c.billing_key = 'synthetic-billing-key'
         and to_jsonb(c) = to_jsonb(before)
     )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from (
  select
    pg_get_functiondef('public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)'::regprocedure) as extend_def,
    pg_get_functiondef('public.revert_gym_period_free_extension(uuid, timestamptz)'::regprocedure) as revert_def
) as defs;

insert into p1_27_results (test_name, status, detail)
select
  'only the owner and service_role can execute the extension functions',
  case
    when has_function_privilege('public', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = true
     and has_function_privilege('postgres', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = true
     and has_function_privilege('public', 'public.revert_gym_period_free_extension(uuid, timestamptz)', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.revert_gym_period_free_extension(uuid, timestamptz)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.revert_gym_period_free_extension(uuid, timestamptz)', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.revert_gym_period_free_extension(uuid, timestamptz)', 'EXECUTE') = true
     and has_function_privilege('postgres', 'public.revert_gym_period_free_extension(uuid, timestamptz)', 'EXECUTE') = true
    then 'PASS' else 'FAIL'
  end,
  'compared';

do $$
declare
  v_extend_message text;
  v_revert_message text;
  v_gym_id uuid;
  v_end timestamptz;
begin
  select untouched_gym_id, future_end into v_gym_id, v_end from p1_27_context;

  begin
    execute 'set local role anon';
    perform public.extend_gym_period_free(
      v_gym_id,
      v_end,
      v_end + interval '1 day',
      'synthetic reason'
    );
    execute 'reset role';
    v_extend_message := 'call returned';
  exception when others then
    execute 'reset role';
    v_extend_message := sqlerrm;
  end;

  begin
    execute 'set local role authenticated';
    perform public.revert_gym_period_free_extension(v_gym_id, v_end);
    execute 'reset role';
    v_revert_message := 'call returned';
  exception when others then
    execute 'reset role';
    v_revert_message := sqlerrm;
  end;

  insert into p1_27_results
  values (
    'anon and authenticated cannot execute the functions',
    case
      when v_extend_message ilike '%permission denied%'
       and v_revert_message ilike '%permission denied%'
       and exists (
         select 1
         from public.gyms g
         join p1_27_gym_before before on before.id = g.id
         where g.id = v_gym_id
           and to_jsonb(g) = to_jsonb(before)
       )
      then 'PASS' else 'FAIL'
    end,
    v_extend_message || ' | ' || v_revert_message
  );
end;
$$;

do $$
declare
  v_message text;
  v_old timestamptz;
  v_new timestamptz;
  v_flag text;
begin
  -- now() does not move inside this transaction, so plant an older
  -- timestamp with triggers off, then let a normal update stamp it.
  execute 'set local session_replication_role to replica';
  update public.gyms g
  set updated_at = now() - interval '2 days'
  from p1_27_context ctx
  where g.id = ctx.untouched_gym_id;
  execute 'set local session_replication_role to origin';

  select g.updated_at into v_old
  from public.gyms g
  join p1_27_context ctx on ctx.untouched_gym_id = g.id;

  update public.gyms g
  set phone = '000-000-0001'
  from p1_27_context ctx
  where g.id = ctx.untouched_gym_id;

  select g.updated_at, current_setting('app.preserve_updated_at', true)
  into v_new, v_flag
  from public.gyms g
  join p1_27_context ctx on ctx.untouched_gym_id = g.id;

  if v_new > v_old and coalesce(v_flag, '') <> '1' then
    v_message := 'refreshed';
  else
    v_message := 'kept flag=' || coalesce(v_flag, '');
  end if;

  insert into p1_27_results
  values (
    'ordinary gym updates still refresh updated_at',
    case when v_message = 'refreshed' then 'PASS' else 'FAIL' end,
    v_message
  );
end;
$$;

insert into p1_27_results (test_name, status, detail)
select
  'guarded failures leave the other synthetic gyms unchanged',
  case
    when not exists (
      select 1
      from public.gyms g
      join p1_27_gym_before before on before.id = g.id
      join p1_27_context ctx on g.id in (
        ctx.untouched_gym_id,
        ctx.wrong_expected_gym_id,
        ctx.not_future_gym_id,
        ctx.free_gym_id,
        ctx.complimentary_gym_id,
        ctx.canceled_gym_id,
        ctx.in_progress_gym_id
      )
      where g.id <> ctx.untouched_gym_id
        and to_jsonb(g) is distinct from to_jsonb(before)
    )
    then 'PASS' else 'FAIL'
  end,
  'compared';

create temp table p1_27_rows_before_rollback on commit drop as
select id, current_period_end, updated_at, auto_renew, plan_code, subscription_status, complimentary_pro
from public.gyms;

\ir p1_27_gym_period_free_extension_rollback.sql

insert into p1_27_results (test_name, status, detail)
select
  'rollback drops only the new extension functions',
  case
    when to_regprocedure('public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)') is null
     and to_regprocedure('public.revert_gym_period_free_extension(uuid, timestamptz)') is null
     and to_regprocedure('public.keep_gym_updated_at_on_request()') is null
     and to_regclass('public.gyms') is not null
     and not exists (
       select 1
       from pg_trigger
       where tgname = 'gyms_zz_keep_updated_at'
         and tgrelid = 'public.gyms'::regclass
     )
     and not exists (
       select 1
       from public.gyms g
       join p1_27_rows_before_rollback before on before.id = g.id
       where g.current_period_end is distinct from before.current_period_end
          or g.updated_at is distinct from before.updated_at
          or g.auto_renew is distinct from before.auto_renew
          or g.plan_code is distinct from before.plan_code
          or g.subscription_status is distinct from before.subscription_status
          or g.complimentary_pro is distinct from before.complimentary_pro
     )
    then 'PASS' else 'FAIL'
  end,
  'compared';

\ir p1_27_gym_period_free_extension.sql

insert into p1_27_results (test_name, status, detail)
select
  'reapplying the migration restores the functions',
  case
    when to_regprocedure('public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)') is not null
     and to_regprocedure('public.revert_gym_period_free_extension(uuid, timestamptz)') is not null
     and has_function_privilege('anon', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.extend_gym_period_free(uuid, timestamptz, timestamptz, text)', 'EXECUTE') = true
    then 'PASS' else 'FAIL'
  end,
  'compared';

create temp table p1_27_reapply_extend on commit drop as
select public.extend_gym_period_free(
  ctx.revert_gym_id,
  ctx.future_end,
  ctx.future_end + interval '7 days',
  'synthetic reapplied extension'
) as result
from p1_27_context ctx;

insert into p1_27_results (test_name, status, detail)
select
  'the restored function can extend one synthetic gym once',
  case
    when extended.result->>'noop' = 'false'
     and (extended.result->>'history_count')::integer = 1
     and g.current_period_end = ctx.future_end + interval '7 days'
     and g.auto_renew = false
     and g.plan_code = 'pro'
     and g.subscription_status = 'active'
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_27_reapply_extend extended
join p1_27_context ctx on true
join public.gyms g on g.id = ctx.revert_gym_id;

select test_name, status, detail
from p1_27_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_27_results where status <> 'PASS') then
    raise exception 'p1_27 tests failed';
  end if;
end;
$$;

rollback;
