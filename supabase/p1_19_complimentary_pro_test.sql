-- Synthetic complimentary Pro checks. This script rolls back.
-- Gym ids are generated here. No production gym is read or written.

begin;

set local timezone to 'UTC';

create temp table p1_19_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_19_context (
  comp_gym_id uuid not null,
  comp_user_id uuid not null,
  comp_pay_gym_id uuid not null,
  comp_legacy_gym_id uuid not null,
  comp_credential_gym_id uuid not null,
  comp_credential_user_id uuid not null,
  control_due_gym_id uuid not null,
  comp_due_gym_id uuid not null,
  active_gym_id uuid not null,
  active_user_id uuid not null,
  expired_gym_id uuid not null,
  expired_user_id uuid not null,
  bad_plan_gym_id uuid not null,
  bad_status_gym_id uuid not null,
  bad_autorenew_gym_id uuid not null,
  bad_column_credential_gym_id uuid not null,
  bad_private_credential_gym_id uuid not null,
  noncomp_core_gym_id uuid not null,
  noncomp_legacy_gym_id uuid not null,
  past_period_end timestamptz not null,
  future_period_end timestamptz not null
) on commit drop;

insert into p1_19_context
select
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  now() - interval '2 days',
  now() + interval '30 days';

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  email,
  '',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_19_context ctx
cross join lateral (
  values
    (ctx.comp_user_id, 'p1_19_comp@example.invalid'),
    (ctx.comp_credential_user_id, 'p1_19_comp_credential@example.invalid'),
    (ctx.active_user_id, 'p1_19_active@example.invalid'),
    (ctx.expired_user_id, 'p1_19_expired@example.invalid')
) as users_to_insert(user_id, email);

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
from p1_19_context ctx
cross join lateral (
  values
    (ctx.comp_gym_id, 'Synthetic Comp Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.comp_pay_gym_id, 'Synthetic Comp Pay Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.comp_legacy_gym_id, 'Synthetic Comp Legacy Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.comp_credential_gym_id, 'Synthetic Comp Credential Gym', 'pro', -1, 'active', ctx.future_period_end, 'toss', 'synthetic-comp-customer', 'synthetic-comp-billing-ref', false, true),
    (ctx.control_due_gym_id, 'Synthetic Control Due Gym', 'pro', -1, 'active', ctx.past_period_end, 'toss', 'synthetic-control-customer', 'synthetic-control-billing-ref', true, false),
    (ctx.comp_due_gym_id, 'Synthetic Comp Due Gym', 'pro', -1, 'active', ctx.past_period_end, 'toss', 'synthetic-comp-due-customer', 'synthetic-comp-due-billing-ref', true, true),
    (ctx.active_gym_id, 'Synthetic Active Gym', 'pro', -1, 'active', ctx.future_period_end, 'toss', 'synthetic-active-customer', 'synthetic-active-billing-ref', true, false),
    (ctx.expired_gym_id, 'Synthetic Expired Gym', 'pro', -1, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.bad_plan_gym_id, 'Synthetic Bad Plan Gym', 'free', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.bad_status_gym_id, 'Synthetic Bad Status Gym', 'pro', 20, 'canceled', ctx.future_period_end, null::text, null::text, null::text, false, false),
    (ctx.bad_autorenew_gym_id, 'Synthetic Bad Autorenew Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, true, false),
    (ctx.bad_column_credential_gym_id, 'Synthetic Column Credential Gym', 'pro', 20, 'active', ctx.past_period_end, 'toss', null::text, 'synthetic-column-billing-ref', false, false),
    (ctx.bad_private_credential_gym_id, 'Synthetic Private Credential Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.noncomp_core_gym_id, 'Synthetic Noncomp Core Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false),
    (ctx.noncomp_legacy_gym_id, 'Synthetic Noncomp Legacy Gym', 'pro', 20, 'active', ctx.past_period_end, null::text, null::text, null::text, false, false)
) as gyms_to_insert(
  gym_id, gym_name, plan_code, member_limit, subscription_status, current_period_end,
  billing_provider, billing_customer_id, billing_subscription_id, auto_renew, complimentary_pro
);

insert into private.billing_credentials (gym_id, provider, billing_key)
select bad_private_credential_gym_id, 'toss', 'synthetic-private-billing-key'
from p1_19_context;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'Synthetic User'
from p1_19_context ctx
cross join lateral (
  values
    (ctx.comp_user_id, ctx.comp_gym_id),
    (ctx.comp_credential_user_id, ctx.comp_credential_gym_id),
    (ctx.active_user_id, ctx.active_gym_id),
    (ctx.expired_user_id, ctx.expired_gym_id)
) as profiles_to_insert(user_id, gym_id)
on conflict (id) do update
set gym_id = excluded.gym_id, name = excluded.name;

create temp table p1_19_comp_before on commit drop as
select
  g.id,
  g.plan_code,
  g.member_limit,
  g.subscription_status,
  g.trial_ends_at,
  g.current_period_end,
  g.billing_provider,
  g.billing_customer_id,
  g.billing_subscription_id,
  g.auto_renew,
  g.name,
  g.phone,
  g.complimentary_pro,
  g.complimentary_pro_at,
  g.complimentary_pro_reason
from public.gyms g
join p1_19_context ctx on ctx.comp_gym_id = g.id;

create temp table p1_19_apply_result on commit drop as
select public.apply_complimentary_pro(ctx.comp_gym_id, 'synthetic-decision-ref') as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'apply sets only the complimentary marker and one zero-amount history row',
  case
    when applied.result->>'ok' = 'true'
     and applied.result->>'already_applied' = 'false'
     and g.complimentary_pro = true
     and g.complimentary_pro_at is not null
     and g.complimentary_pro_reason = 'synthetic-decision-ref'
     and g.plan_code = before.plan_code
     and g.member_limit = before.member_limit
     and g.subscription_status = before.subscription_status
     and g.trial_ends_at = before.trial_ends_at
     and g.current_period_end = before.current_period_end
     and g.billing_provider is not distinct from before.billing_provider
     and g.billing_customer_id is not distinct from before.billing_customer_id
     and g.billing_subscription_id is not distinct from before.billing_subscription_id
     and g.auto_renew = before.auto_renew
     and g.name = before.name
     and g.phone = before.phone
     and before.complimentary_pro = false
     and (
       select count(*)
       from public.subscriptions s
       where s.gym_id = g.id
         and s.amount_krw = 0
         and s.plan_code = 'pro'
         and s.status = 'active'
         and s.provider = 'manual'
         and s.ends_at is not distinct from before.current_period_end
         and s.raw->>'reason' = 'complimentary_pro'
         and s.raw->>'decision_ref' = 'synthetic-decision-ref'
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_apply_result applied
join p1_19_context ctx on true
join public.gyms g on g.id = ctx.comp_gym_id
join p1_19_comp_before before on before.id = g.id;

create temp table p1_19_marker_at on commit drop as
select g.complimentary_pro_at
from public.gyms g
join p1_19_context ctx on ctx.comp_gym_id = g.id;

create temp table p1_19_apply_again on commit drop as
select public.apply_complimentary_pro(ctx.comp_gym_id, 'synthetic-decision-another') as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'apply rerun is idempotent',
  case
    when again.result->>'ok' = 'true'
     and again.result->>'already_applied' = 'true'
     and g.complimentary_pro_at = marker.complimentary_pro_at
     and g.complimentary_pro_reason = 'synthetic-decision-ref'
     and g.current_period_end = before.current_period_end
     and g.auto_renew = false
     and g.subscription_status = 'active'
     and g.plan_code = before.plan_code
     and g.member_limit = before.member_limit
     and (
       select count(*)
       from public.subscriptions s
       where s.gym_id = g.id
         and s.amount_krw = 0
         and s.raw->>'reason' = 'complimentary_pro'
     ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_apply_again again
join p1_19_context ctx on true
join public.gyms g on g.id = ctx.comp_gym_id
join p1_19_comp_before before on before.id = g.id
join p1_19_marker_at marker on true;

insert into p1_19_results (test_name, status, detail)
select
  'comp gym past period end keeps Pro and lifts the member limit',
  case
    when public.gym_has_pro_access(g) = true
     and public.gym_effective_member_limit(g.id) = -1
     and g.current_period_end < now()
     and g.member_limit = 20
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.gyms g
join p1_19_context ctx on ctx.comp_gym_id = g.id;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.comp_gym_id, 'Synthetic Comp Member ' || gs, current_date, current_date + 30
from p1_19_context ctx
cross join generate_series(1, 21) as gs;

insert into p1_19_results (test_name, status, detail)
select
  'comp gym accepts a member past the free limit',
  case
    when (
      select count(*)
      from public.members m
      join p1_19_context ctx on ctx.comp_gym_id = m.gym_id
    ) = 21
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into p1_19_results (test_name, status, detail)
select
  'expired non-comp gym stays limited',
  case
    when public.gym_has_pro_access(g) = false
     and public.gym_effective_member_limit(g.id) = 20
     and g.complimentary_pro = false
     and g.current_period_end < now()
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.gyms g
join p1_19_context ctx on ctx.expired_gym_id = g.id;

insert into public.members (gym_id, name, start_date, expire_date)
select ctx.expired_gym_id, 'Synthetic Expired Member ' || gs, current_date, current_date + 30
from p1_19_context ctx
cross join generate_series(1, 20) as gs;

do $$
declare
  v_detail text;
  v_count integer;
begin
  begin
    insert into public.members (gym_id, name, start_date, expire_date)
    select expired_gym_id, 'Synthetic Expired Member 21', current_date, current_date + 30
    from p1_19_context;

    insert into p1_19_results
    values ('expired non-comp gym rejects member 21', 'FAIL', 'insert succeeded');
  exception when others then
    v_detail := sqlerrm;
    select count(*) into v_count
    from public.members m
    join p1_19_context ctx on ctx.expired_gym_id = m.gym_id;

    insert into p1_19_results
    values (
      'expired non-comp gym rejects member 21',
      case
        when v_detail like 'MEMBER_LIMIT_REACHED:%' and v_count = 20 then 'PASS'
        else 'FAIL'
      end,
      'compared'
    );
  end;
end;
$$;

create temp table p1_19_due_claims on commit drop as
select *
from public.claim_due_toss_subscription_charges(now(), 50, 10000);

insert into p1_19_results (test_name, status, detail)
select
  'comp gyms are excluded from auto-charge selection',
  case
    when not exists (
      select 1
      from p1_19_due_claims c
      join p1_19_context ctx on c.gym_id in (ctx.comp_gym_id, ctx.comp_due_gym_id)
    )
     and exists (
      select 1
      from p1_19_due_claims c
      join p1_19_context ctx on c.gym_id = ctx.control_due_gym_id
    )
     and (
      select count(*)
      from p1_19_due_claims c
      join p1_19_context ctx on c.gym_id = ctx.control_due_gym_id
    ) = 1
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

create temp table p1_19_comp_claim on commit drop as
select public.claim_initial_billing_attempt(
  ctx.comp_gym_id,
  ctx.comp_user_id,
  'synthetic-customer-key',
  10000
) as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'initial checkout for a comp gym is rejected as already active',
  case
    when result->>'ok' = 'true'
     and result->>'action' = 'already_completed'
     and result->>'can_charge' = 'false'
     and result->>'already_completed' = 'true'
     and result->>'complimentary_pro' = 'true'
     and (result->>'current_period_end')::timestamptz = g.current_period_end
     and (
       select count(*)
       from public.payment_attempts pa
       where pa.gym_id = g.id
     ) = 0
    then 'PASS'
    else 'FAIL'
  end,
  coalesce(result->>'action', 'missing')
from p1_19_comp_claim
join p1_19_context ctx on true
join public.gyms g on g.id = ctx.comp_gym_id;

do $$
declare
  v_message text;
  v_status text;
  v_auto_renew boolean;
begin
  perform set_config(
    'request.jwt.claim.sub',
    (select comp_user_id::text from p1_19_context),
    true
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  begin
    perform public.cancel_gym_subscription();
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  select subscription_status, auto_renew
  into v_status, v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.comp_gym_id = g.id;

  insert into p1_19_results
  values (
    'cancel rejects a comp gym',
    case
      when v_message = 'COMPLIMENTARY_PRO'
       and v_status = 'active'
       and v_auto_renew = false
      then 'PASS'
      else 'FAIL'
    end,
    v_message
  );

  begin
    perform public.resume_gym_subscription();
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  select subscription_status, auto_renew
  into v_status, v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.comp_gym_id = g.id;

  insert into p1_19_results
  values (
    'resume rejects a comp gym',
    case
      when v_message = 'COMPLIMENTARY_PRO'
       and v_status = 'active'
       and v_auto_renew = false
      then 'PASS'
      else 'FAIL'
    end,
    v_message
  );
end;
$$;

do $$
declare
  v_message text;
  v_auto_renew boolean;
  v_has_credential boolean;
begin
  perform set_config(
    'request.jwt.claim.sub',
    (select comp_credential_user_id::text from p1_19_context),
    true
  );

  select private.gym_has_billing_credential(ctx.comp_credential_gym_id)
  into v_has_credential
  from p1_19_context ctx;

  begin
    perform public.cancel_gym_subscription();
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  select auto_renew into v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.comp_credential_gym_id = g.id;

  insert into p1_19_results
  values (
    'cancel rejects a comp gym that still has a billing reference',
    case
      when v_has_credential
       and v_message = 'COMPLIMENTARY_PRO'
       and v_auto_renew = false
      then 'PASS'
      else 'FAIL'
    end,
    v_message
  );

  begin
    perform public.resume_gym_subscription();
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  select auto_renew into v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.comp_credential_gym_id = g.id;

  insert into p1_19_results
  values (
    'resume rejects a comp gym that still has a billing reference',
    case
      when v_message = 'COMPLIMENTARY_PRO' and v_auto_renew = false then 'PASS'
      else 'FAIL'
    end,
    v_message
  );
end;
$$;

create temp table p1_19_comp_summary on commit drop as
select public.get_billing_summary() as summary
from (
  select set_config(
    'request.jwt.claim.sub',
    (select comp_user_id::text from p1_19_context),
    true
  )
) as configured;

insert into p1_19_results (test_name, status, detail)
select
  'billing summary exposes complimentary Pro',
  case
    when summary->>'complimentary_pro' = 'true'
     and summary->>'has_pro' = 'true'
     and summary->>'member_limit' = '-1'
     and summary->>'can_add_member' = 'true'
     and summary->>'can_cancel' = 'false'
     and summary->>'can_resume' = 'false'
     and summary->>'auto_renew' = 'false'
     and summary->>'subscription_status' = 'active'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_comp_summary;

do $$
begin
  perform set_config('app.allow_billing_update', '0', true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  perform set_config(
    'request.jwt.claim.sub',
    (select comp_user_id::text from p1_19_context),
    true
  );
end;
$$;

update public.gyms g
set
  name = 'Owner tried to rename',
  complimentary_pro = false,
  complimentary_pro_at = null,
  complimentary_pro_reason = 'owner-flip',
  auto_renew = true,
  plan_code = 'free'
from p1_19_context ctx
where g.id = ctx.comp_gym_id;

update public.gyms g
set complimentary_pro = true,
    complimentary_pro_reason = 'owner-grant'
from p1_19_context ctx
where g.id = ctx.active_gym_id;

insert into p1_19_results (test_name, status, detail)
select
  'owner direct update cannot flip the complimentary marker',
  case
    when comp.complimentary_pro = true
     and comp.complimentary_pro_reason = 'synthetic-decision-ref'
     and comp.complimentary_pro_at is not null
     and comp.auto_renew = false
     and comp.plan_code = 'pro'
     and comp.name = 'Owner tried to rename'
     and active.complimentary_pro = false
     and active.complimentary_pro_reason is null
     and active.plan_code = 'pro'
     and active.auto_renew = true
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.gyms comp
join p1_19_context ctx on ctx.comp_gym_id = comp.id
join public.gyms active on active.id = ctx.active_gym_id;

do $$
begin
  perform set_config('request.jwt.claim.role', 'service_role', true);
end;
$$;

update public.gyms g
set name = before.name
from p1_19_comp_before before
where g.id = before.id;

do $$
begin
  perform set_config('request.jwt.claim.role', '', true);
  perform set_config('app.allow_billing_update', '0', true);
end;
$$;

insert into p1_19_results (test_name, status, detail)
select
  'owner rename does not clear the marker',
  case
    when g.name = before.name
     and g.complimentary_pro = true
     and g.complimentary_pro_reason = 'synthetic-decision-ref'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.gyms g
join p1_19_comp_before before on before.id = g.id;

do $$
begin
  perform public.apply_complimentary_pro(
    (select comp_pay_gym_id from p1_19_context),
    'synthetic-decision-ref'
  );
  perform public.apply_complimentary_pro(
    (select comp_legacy_gym_id from p1_19_context),
    'synthetic-decision-ref'
  );
end;
$$;

insert into public.payment_attempts (
  gym_id, provider, payment_type, amount_krw, order_id, payment_key,
  target_period_start, target_period_end, status, customer_key
)
select
  ctx.comp_pay_gym_id,
  'toss',
  'initial_billing',
  10000,
  'p1_19_comp_pay_order',
  'p1_19_comp_pay_key',
  ctx.past_period_end,
  ctx.future_period_end,
  'charge_succeeded',
  'synthetic-pay-customer'
from p1_19_context ctx
union all
select
  ctx.noncomp_core_gym_id,
  'toss',
  'initial_billing',
  10000,
  'p1_19_noncomp_pay_order',
  'p1_19_noncomp_pay_key',
  ctx.past_period_end,
  ctx.future_period_end,
  'charge_succeeded',
  'synthetic-pay-customer'
from p1_19_context ctx;

create temp table p1_19_pay_activation on commit drop as
select
  pa.order_id,
  public.activate_payment_attempt_core(pa.id, false) as result
from public.payment_attempts pa
where pa.order_id in ('p1_19_comp_pay_order', 'p1_19_noncomp_pay_order');

insert into p1_19_results (test_name, status, detail)
select
  'payment activation does not re-enable auto_renew for a comp gym',
  case
    when activation.result->>'ok' = 'true'
     and g.auto_renew = false
     and g.complimentary_pro = true
     and g.subscription_status = 'active'
     and noncomp.auto_renew = true
     and noncomp.complimentary_pro = false
     and noncomp_activation.result->>'ok' = 'true'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_pay_activation activation
join public.gyms g on true
join p1_19_context ctx on ctx.comp_pay_gym_id = g.id
join public.gyms noncomp on noncomp.id = ctx.noncomp_core_gym_id
join p1_19_pay_activation noncomp_activation
  on noncomp_activation.order_id = 'p1_19_noncomp_pay_order'
where activation.order_id = 'p1_19_comp_pay_order';

do $$
begin
  perform public.activate_gym_pro(
    (select comp_legacy_gym_id from p1_19_context),
    'toss',
    'monthly',
    0,
    null,
    null,
    null,
    jsonb_build_object('reason', 'synthetic-legacy'),
    true
  );
  perform public.activate_gym_pro(
    (select noncomp_legacy_gym_id from p1_19_context),
    'toss',
    'monthly',
    0,
    null,
    null,
    null,
    jsonb_build_object('reason', 'synthetic-legacy'),
    true
  );
end;
$$;

insert into p1_19_results (test_name, status, detail)
select
  'legacy activation does not re-enable auto_renew for a comp gym',
  case
    when comp.auto_renew = false
     and comp.complimentary_pro = true
     and noncomp.auto_renew = true
     and noncomp.complimentary_pro = false
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from public.gyms comp
join p1_19_context ctx on ctx.comp_legacy_gym_id = comp.id
join public.gyms noncomp on noncomp.id = ctx.noncomp_legacy_gym_id;

do $$
declare
  v_name text;
  v_gym_id uuid;
  v_message text;
  v_marked boolean;
begin
  for v_name, v_gym_id in
    select *
    from (
      select 'apply aborts when the plan is not pro'::text, bad_plan_gym_id from p1_19_context
      union all
      select 'apply aborts when status is not active', bad_status_gym_id from p1_19_context
      union all
      select 'apply aborts when auto_renew is on', bad_autorenew_gym_id from p1_19_context
      union all
      select 'apply aborts when a billing reference exists', bad_column_credential_gym_id from p1_19_context
      union all
      select 'apply aborts when a private billing key exists', bad_private_credential_gym_id from p1_19_context
    ) as cases(test_name, gym_id)
  loop
    begin
      perform public.apply_complimentary_pro(v_gym_id, 'synthetic-decision-ref');
      v_message := 'call returned';
    exception when others then
      v_message := sqlerrm;
    end;

    select complimentary_pro into v_marked
    from public.gyms
    where id = v_gym_id;

    insert into p1_19_results
    values (
      v_name,
      case
        when v_message like 'COMPLIMENTARY_PRO_PRECONDITION_FAILED:%'
         and v_marked = false
         and not exists (
           select 1
           from public.subscriptions s
           where s.gym_id = v_gym_id
             and s.raw->>'reason' = 'complimentary_pro'
         )
        then 'PASS'
        else 'FAIL'
      end,
      v_message
    );
  end loop;

  begin
    perform public.apply_complimentary_pro(null, 'synthetic-decision-ref');
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;
  insert into p1_19_results
  values (
    'apply aborts when the gym id is missing',
    case when v_message = 'COMPLIMENTARY_PRO_TARGET_COUNT' then 'PASS' else 'FAIL' end,
    v_message
  );

  begin
    perform public.apply_complimentary_pro(gen_random_uuid(), 'synthetic-decision-ref');
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;
  insert into p1_19_results
  values (
    'apply aborts unless the target count is exactly one',
    case when v_message = 'COMPLIMENTARY_PRO_TARGET_COUNT' then 'PASS' else 'FAIL' end,
    v_message
  );

  begin
    perform public.apply_complimentary_pro(
      (select bad_plan_gym_id from p1_19_context),
      '   '
    );
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;
  insert into p1_19_results
  values (
    'apply aborts without a decision ref',
    case
      when v_message = 'COMPLIMENTARY_PRO_DECISION_REF_REQUIRED' then 'PASS'
      else 'FAIL'
    end,
    v_message
  );
end;
$$;

create temp table p1_19_expired_claim on commit drop as
select public.claim_initial_billing_attempt(
  ctx.expired_gym_id,
  ctx.expired_user_id,
  'synthetic-expired-customer',
  10000
) as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'expired non-comp gym can still start initial billing',
  case
    when result->>'action' = 'charge'
     and result->>'can_charge' = 'true'
    then 'PASS'
    else 'FAIL'
  end,
  coalesce(result->>'action', 'missing')
from p1_19_expired_claim;

create temp table p1_19_active_claim on commit drop as
select public.claim_initial_billing_attempt(
  ctx.active_gym_id,
  ctx.active_user_id,
  'synthetic-active-customer',
  10000
) as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'unexpired non-comp Pro is still already active',
  case
    when result->>'action' = 'already_completed'
     and result->>'can_charge' = 'false'
     and coalesce(result->>'complimentary_pro', 'false') = 'false'
    then 'PASS'
    else 'FAIL'
  end,
  coalesce(result->>'action', 'missing')
from p1_19_active_claim;

do $$
declare
  v_result jsonb;
  v_status text;
  v_auto_renew boolean;
begin
  perform set_config(
    'request.jwt.claim.sub',
    (select active_user_id::text from p1_19_context),
    true
  );
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_result := public.cancel_gym_subscription();

  select subscription_status, auto_renew
  into v_status, v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.active_gym_id = g.id;

  insert into p1_19_results
  values (
    'non-comp cancel still turns auto_renew off',
    case
      when v_result->>'ok' = 'true'
       and v_status = 'canceled'
       and v_auto_renew = false
      then 'PASS'
      else 'FAIL'
    end,
    coalesce(v_status, 'missing')
  );

  v_result := public.resume_gym_subscription();

  select subscription_status, auto_renew
  into v_status, v_auto_renew
  from public.gyms g
  join p1_19_context ctx on ctx.active_gym_id = g.id;

  insert into p1_19_results
  values (
    'non-comp resume still turns auto_renew on',
    case
      when v_result->>'ok' = 'true'
       and v_status = 'active'
       and v_auto_renew = true
      then 'PASS'
      else 'FAIL'
    end,
    coalesce(v_status, 'missing')
  );
end;
$$;

create temp table p1_19_active_summary on commit drop as
select public.get_billing_summary() as summary
from (
  select set_config(
    'request.jwt.claim.sub',
    (select active_user_id::text from p1_19_context),
    true
  )
) as configured;

insert into p1_19_results (test_name, status, detail)
select
  'non-comp billing summary stays unchanged',
  case
    when summary->>'complimentary_pro' = 'false'
     and summary->>'has_pro' = 'true'
     and summary->>'can_cancel' = 'true'
     and summary->>'auto_renew' = 'true'
     and summary->>'subscription_status' = 'active'
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_active_summary;

create temp table p1_19_rollback_result on commit drop as
select public.rollback_complimentary_pro(ctx.comp_gym_id) as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'rollback clears the marker and restores the prior gym state',
  case
    when rolled.result->>'ok' = 'true'
     and rolled.result->>'cleared' = 'true'
     and g.complimentary_pro = false
     and g.complimentary_pro_at is null
     and g.complimentary_pro_reason is null
     and g.plan_code = before.plan_code
     and g.member_limit = before.member_limit
     and g.subscription_status = before.subscription_status
     and g.trial_ends_at = before.trial_ends_at
     and g.current_period_end = before.current_period_end
     and g.billing_provider is not distinct from before.billing_provider
     and g.billing_customer_id is not distinct from before.billing_customer_id
     and g.billing_subscription_id is not distinct from before.billing_subscription_id
     and g.auto_renew = before.auto_renew
     and g.name = before.name
     and g.phone = before.phone
     and public.gym_has_pro_access(g) = false
     and public.gym_effective_member_limit(g.id) = 20
     and not exists (
       select 1
       from public.subscriptions s
       where s.gym_id = g.id
         and s.raw->>'reason' = 'complimentary_pro'
     )
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_rollback_result rolled
join p1_19_context ctx on true
join public.gyms g on g.id = ctx.comp_gym_id
join p1_19_comp_before before on before.id = g.id;

create temp table p1_19_rollback_again on commit drop as
select public.rollback_complimentary_pro(ctx.comp_gym_id) as result
from p1_19_context ctx;

insert into p1_19_results (test_name, status, detail)
select
  'rollback rerun leaves the cleared gym unchanged',
  case
    when result->>'ok' = 'true'
     and result->>'cleared' = 'false'
     and g.complimentary_pro = false
     and g.current_period_end = before.current_period_end
     and g.auto_renew = before.auto_renew
    then 'PASS'
    else 'FAIL'
  end,
  'compared'
from p1_19_rollback_again
join p1_19_context ctx on true
join public.gyms g on g.id = ctx.comp_gym_id
join p1_19_comp_before before on before.id = g.id;

insert into p1_19_results (test_name, status, detail)
select
  'auto-renewal reconciliation is unchanged',
  case
    when position(
      'complimentary_pro' in pg_get_functiondef(
        'public.claim_stale_auto_renewal_reconciliation_attempts(timestamptz, integer)'::regprocedure
      )
    ) = 0
     and position(
      'complimentary_pro' in pg_get_functiondef(
        'public.claim_subscription_charge_dispatch(uuid)'::regprocedure
      )
    ) = 0
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into p1_19_results (test_name, status, detail)
select
  'apply and rollback execute only for owner and service_role',
  case
    when has_function_privilege('public', 'public.apply_complimentary_pro(uuid, text)', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.apply_complimentary_pro(uuid, text)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.apply_complimentary_pro(uuid, text)', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.apply_complimentary_pro(uuid, text)', 'EXECUTE') = true
     and has_function_privilege('public', 'public.rollback_complimentary_pro(uuid)', 'EXECUTE') = false
     and has_function_privilege('anon', 'public.rollback_complimentary_pro(uuid)', 'EXECUTE') = false
     and has_function_privilege('authenticated', 'public.rollback_complimentary_pro(uuid)', 'EXECUTE') = false
     and has_function_privilege('service_role', 'public.rollback_complimentary_pro(uuid)', 'EXECUTE') = true
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

do $$
declare
  v_message text;
begin
  begin
    execute 'set local role authenticated';
    perform public.apply_complimentary_pro(gen_random_uuid(), 'synthetic-decision-ref');
    execute 'reset role';
    v_message := 'call returned';
  exception when others then
    execute 'reset role';
    v_message := sqlerrm;
  end;

  insert into p1_19_results
  values (
    'authenticated cannot execute apply',
    case when v_message ilike '%permission denied%' then 'PASS' else 'FAIL' end,
    v_message
  );
end;
$$;

select test_name, status, detail
from p1_19_results
order by test_name;

rollback;
