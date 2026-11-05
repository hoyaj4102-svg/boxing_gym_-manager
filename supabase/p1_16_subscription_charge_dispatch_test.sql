-- Dispatch lock for one auto-renewal attempt.
-- Synthetic rows only. Rolls back. Does not call a payment provider.

begin;

create temp table p1_16_dispatch_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_16_dispatch_context (
  gym_id uuid not null,
  attempt_id uuid not null,
  second_attempt_id uuid not null,
  completed_attempt_id uuid not null
) on commit drop;

insert into p1_16_dispatch_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid()
);

insert into public.gyms (id, name, owner_name, phone)
select gym_id, 'P1-16 Dispatch Gym', 'Owner', '010-0000-0000'
from p1_16_dispatch_context;

insert into public.payment_attempts (
  id,
  gym_id,
  provider,
  payment_type,
  amount_krw,
  order_id,
  status
)
select
  attempt_id,
  gym_id,
  'toss',
  'auto_renewal',
  10000,
  'p1_16_dispatch_first',
  'initiated'
from p1_16_dispatch_context
union all
select
  second_attempt_id,
  gym_id,
  'toss',
  'auto_renewal',
  10000,
  'p1_16_dispatch_second',
  'initiated'
from p1_16_dispatch_context
union all
select
  completed_attempt_id,
  gym_id,
  'toss',
  'auto_renewal',
  10000,
  'p1_16_dispatch_completed',
  'completed'
from p1_16_dispatch_context;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'first dispatch is accepted',
  case
    when public.claim_subscription_charge_dispatch(ctx.attempt_id) then 'PASS'
    else 'FAIL'
  end,
  'first call'
from p1_16_dispatch_context ctx;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'second dispatch is rejected',
  case
    when public.claim_subscription_charge_dispatch(ctx.attempt_id) then 'FAIL'
    else 'PASS'
  end,
  'second call'
from p1_16_dispatch_context ctx;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'dispatch timestamp is stored once',
  case
    when pa.charge_dispatched_at is not null then 'PASS'
    else 'FAIL'
  end,
  'timestamp'
from p1_16_dispatch_context ctx
join public.payment_attempts pa on pa.id = ctx.attempt_id;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'another initiated attempt can dispatch',
  case
    when public.claim_subscription_charge_dispatch(ctx.second_attempt_id) then 'PASS'
    else 'FAIL'
  end,
  'other attempt'
from p1_16_dispatch_context ctx;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'completed attempt is not dispatched',
  case
    when public.claim_subscription_charge_dispatch(ctx.completed_attempt_id) then 'FAIL'
    else 'PASS'
  end,
  'completed'
from p1_16_dispatch_context ctx;

insert into p1_16_dispatch_results (test_name, status, detail)
select
  'completed attempt timestamp stays empty',
  case
    when pa.charge_dispatched_at is null then 'PASS'
    else 'FAIL'
  end,
  'completed timestamp'
from p1_16_dispatch_context ctx
join public.payment_attempts pa on pa.id = ctx.completed_attempt_id;

do $$
begin
  begin
    execute 'set local role authenticated';
    perform public.claim_subscription_charge_dispatch(null);
    execute 'reset role';
    insert into p1_16_dispatch_results (test_name, status, detail)
    values ('owner role cannot dispatch a charge', 'FAIL', 'statement succeeded');
  exception
    when insufficient_privilege then
      execute 'reset role';
      insert into p1_16_dispatch_results (test_name, status, detail)
      values ('owner role cannot dispatch a charge', 'PASS', 'permission denied');
    when others then
      execute 'reset role';
      insert into p1_16_dispatch_results (test_name, status, detail)
      values ('owner role cannot dispatch a charge', 'FAIL', sqlstate);
  end;
end;
$$;

do $$
declare
  v_gym_id uuid;
  v_attempt_id uuid := gen_random_uuid();
  v_allowed boolean;
  v_repeat boolean;
begin
  select gym_id into v_gym_id
  from p1_16_dispatch_context;

  insert into public.payment_attempts (
    id,
    gym_id,
    provider,
    payment_type,
    amount_krw,
    order_id,
    status
  )
  values (
    v_attempt_id,
    v_gym_id,
    'toss',
    'auto_renewal',
    10000,
    'p1_16_dispatch_service_role',
    'initiated'
  );

  execute 'set local role service_role';
  select public.claim_subscription_charge_dispatch(v_attempt_id) into v_allowed;
  select public.claim_subscription_charge_dispatch(v_attempt_id) into v_repeat;
  execute 'reset role';

  insert into p1_16_dispatch_results (test_name, status, detail)
  values (
    'service role can call dispatch',
    case when v_allowed = true and v_repeat = false then 'PASS' else 'FAIL' end,
    'first call true, second call false'
  );
exception
  when others then
    execute 'reset role';
    insert into p1_16_dispatch_results (test_name, status, detail)
    values ('service role can call dispatch', 'FAIL', sqlstate || ' ' || sqlerrm);
end;
$$;

select test_name, status, detail
from p1_16_dispatch_results
order by test_name;

rollback;
