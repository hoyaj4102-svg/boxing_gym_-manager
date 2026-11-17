-- Same-order retry claim. Synthetic rows only. Rolls back. Does not call Toss.

begin;

create temp table p1_29_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

create temp table p1_29_context (
  gym_id uuid not null,
  initial_gym_id uuid not null,
  user_id uuid not null,
  initial_user_id uuid not null,
  retry_attempt_id uuid not null,
  fresh_attempt_id uuid not null,
  paid_attempt_id uuid not null,
  initial_attempt_id uuid not null,
  blocked_initial_id uuid not null
) on commit drop;

insert into p1_29_context
values (
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

insert into public.gyms (
  id, name, owner_name, phone, plan_code, subscription_status
)
select gym_id, 'P1-29 Retry Gym', 'Owner', '010-0000-0000', 'free', 'expired'
from p1_29_context
union all
select initial_gym_id, 'P1-29 Initial Gym', 'Owner', '010-0000-0000', 'free', 'expired'
from p1_29_context;

create temp table p1_29_users on commit drop as
select user_id, gym_id
from p1_29_context
union all
select initial_user_id, initial_gym_id
from p1_29_context;

insert into auth.users (
  id, instance_id, aud, role, email, encrypted_password,
  email_confirmed_at, created_at, updated_at, raw_app_meta_data, raw_user_meta_data
)
select
  user_id,
  '00000000-0000-0000-0000-000000000000'::uuid,
  'authenticated',
  'authenticated',
  'p1_29_' || replace(user_id::text, '-', '') || '@example.invalid',
  '',
  now(), now(), now(),
  '{"provider":"email","providers":["email"]}'::jsonb,
  '{}'::jsonb
from p1_29_users;

insert into public.profiles (id, gym_id, name)
select user_id, gym_id, 'P1-29 Test User'
from p1_29_users
on conflict (id) do update
set gym_id = excluded.gym_id, name = excluded.name;

insert into public.payment_attempts (
  id, gym_id, user_id, provider, payment_type, amount_krw, order_id,
  customer_key, status, activation_status, recovery_status, error_code, payment_key
)
select
  retry_attempt_id, gym_id, user_id, 'toss', 'auto_renewal', 10000,
  'p1_29_retry_order', 'p1_29_customer', 'initiated', 'not_started', 'none',
  'TOSS_ORDER_NOT_FOUND_RETRY_SAME_ORDER', null
from p1_29_context
union all
select
  fresh_attempt_id, gym_id, user_id, 'toss', 'auto_renewal', 10000,
  'p1_29_fresh_order', 'p1_29_customer', 'initiated', 'not_started', 'none',
  null, null
from p1_29_context
union all
select
  paid_attempt_id, gym_id, user_id, 'toss', 'auto_renewal', 10000,
  'p1_29_paid_order', 'p1_29_customer', 'initiated', 'not_started', 'none',
  'TOSS_ORDER_NOT_FOUND_RETRY_SAME_ORDER', 'p1_29_payment_key'
from p1_29_context
union all
select
  initial_attempt_id, initial_gym_id, initial_user_id, 'toss', 'initial_billing', 10000,
  'p1_29_initial_order', 'p1_29_customer', 'initiated', 'not_started', 'none',
  'TOSS_ORDER_NOT_FOUND_RETRY_SAME_ORDER', null
from p1_29_context
union all
select
  blocked_initial_id, initial_gym_id, initial_user_id, 'toss', 'initial_billing', 10000,
  'p1_29_blocked_initial_order', 'p1_29_customer', 'charge_failed', 'not_started', 'none',
  'REJECT_CARD_COMPANY', null
from p1_29_context;

-- The blocked initial row is a second initial attempt for the same gym.
-- claim_initial returns the newest open attempt, so give the retry row the later time.
update public.payment_attempts
set created_at = now()
where id = (select initial_attempt_id from p1_29_context);

update public.payment_attempts
set created_at = now() - interval '1 minute'
where id = (select blocked_initial_id from p1_29_context);

insert into p1_29_results (test_name, status, detail)
select
  'released auto-renewal attempt is claimed once',
  case
    when count(*) = 1
     and bool_and(order_id = 'p1_29_retry_order')
     and bool_and(payment_attempt_id = (select retry_attempt_id from p1_29_context))
    then 'PASS' else 'FAIL'
  end,
  'claimed=' || count(*)::text
from public.claim_retryable_same_order_charges(10);

insert into p1_29_results (test_name, status, detail)
select
  'claimed attempt keeps its order and holds the dispatch lock',
  case
    when pa.order_id = 'p1_29_retry_order'
     and pa.charge_dispatched_at is not null
     and pa.payment_key is null
    then 'PASS' else 'FAIL'
  end,
  coalesce(pa.order_id, 'none')
from public.payment_attempts pa
join p1_29_context ctx on pa.id = ctx.retry_attempt_id;

insert into p1_29_results (test_name, status, detail)
select
  'second claim does not charge the same order again',
  case when count(*) = 0 then 'PASS' else 'FAIL' end,
  'rows=' || count(*)::text
from public.claim_retryable_same_order_charges(10);

insert into p1_29_results (test_name, status, detail)
select
  'fresh initiated attempt is not treated as a released retry',
  case when pa.charge_dispatched_at is null then 'PASS' else 'FAIL' end,
  'fresh dispatch stays empty'
from public.payment_attempts pa
join p1_29_context ctx on pa.id = ctx.fresh_attempt_id;

insert into p1_29_results (test_name, status, detail)
select
  'attempt that already has a payment key is not claimed',
  case when pa.charge_dispatched_at is null then 'PASS' else 'FAIL' end,
  'paid key stays unclaimed'
from public.payment_attempts pa
join p1_29_context ctx on pa.id = ctx.paid_attempt_id;

insert into p1_29_results (test_name, status, detail)
select
  'initial same-order retry can charge the original order',
  case
    when result->>'can_charge' = 'true'
     and result->>'same_order_retry' = 'true'
     and result->>'order_id' = 'p1_29_initial_order'
     and result->>'payment_attempt_id' = ctx.initial_attempt_id::text
    then 'PASS' else 'FAIL'
  end,
  coalesce(result->>'action', 'none') || ' ' || coalesce(result->>'order_id', 'none')
from p1_29_context ctx
cross join lateral public.claim_initial_billing_attempt(
  ctx.initial_gym_id, ctx.initial_user_id, 'p1_29_customer', 10000
) as result;

select test_name, status, detail
from p1_29_results
order by test_name;

rollback;
