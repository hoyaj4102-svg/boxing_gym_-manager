-- Client write checks for payment-related tables.
-- Re-grants broad writes, applies the restriction, then rolls back.
-- Does not call a payment provider.

begin;

create temp table p1_16_privilege_results (
  test_name text not null,
  status text not null,
  detail text
) on commit drop;

grant insert, update, delete, truncate on table
  public.gyms,
  public.payment_attempts,
  public.checkout_sessions,
  public.subscriptions,
  public.toss_webhook_events
to anon, authenticated;

grant insert, update, delete, truncate on table private.billing_credentials
to anon, authenticated;

select private.enforce_payment_table_write_restrictions();

insert into p1_16_privilege_results (test_name, status, detail)
select
  format('%s %s cannot %s', table_name, role_name, privilege_name),
  case
    when has_table_privilege(role_name, table_name, privilege_name) then 'FAIL'
    else 'PASS'
  end,
  privilege_name
from (
  values
    ('public.gyms'),
    ('public.payment_attempts'),
    ('public.checkout_sessions'),
    ('public.subscriptions'),
    ('public.toss_webhook_events'),
    ('private.billing_credentials')
) as tables(table_name)
cross join (values ('anon'), ('authenticated')) as roles(role_name)
cross join (values ('INSERT'), ('UPDATE'), ('DELETE')) as privileges(privilege_name);

insert into p1_16_privilege_results (test_name, status, detail)
select
  format('service role can %s %s', privilege_name, table_name),
  case
    when has_table_privilege('service_role', table_name, privilege_name) then 'PASS'
    else 'FAIL'
  end,
  privilege_name
from (
  values
    ('public.gyms'),
    ('public.payment_attempts'),
    ('public.checkout_sessions'),
    ('public.subscriptions')
) as tables(table_name)
cross join (values ('SELECT'), ('INSERT'), ('UPDATE'), ('DELETE')) as privileges(privilege_name);

insert into p1_16_privilege_results (test_name, status, detail)
select
  'service role keeps webhook writes',
  case
    when has_table_privilege('service_role', 'public.toss_webhook_events', 'INSERT')
     and has_table_privilege('service_role', 'public.toss_webhook_events', 'UPDATE')
     and not has_table_privilege('service_role', 'public.toss_webhook_events', 'DELETE')
    then 'PASS'
    else 'FAIL'
  end,
  'webhook';

insert into p1_16_privilege_results (test_name, status, detail)
select
  'owner role can still read a gym name',
  case
    when has_column_privilege('authenticated', 'public.gyms', 'name', 'SELECT')
    then 'PASS'
    else 'FAIL'
  end,
  'select name';

insert into p1_16_privilege_results (test_name, status, detail)
select
  'owner role cannot read the gym credential column',
  case
    when has_column_privilege(
      'authenticated',
      'public.gyms',
      'billing_subscription_id',
      'SELECT'
    ) then 'FAIL'
    else 'PASS'
  end,
  'credential column';

do $$
declare
  v_user_id uuid := gen_random_uuid();
  v_gym_id uuid;
  v_result jsonb;
  v_status text;
begin
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
  values (
    v_user_id,
    '00000000-0000-0000-0000-000000000000'::uuid,
    'authenticated',
    'authenticated',
    'p1_16_privilege@example.invalid',
    '',
    now(),
    now(),
    now(),
    '{"provider":"email","providers":["email"]}'::jsonb,
    '{}'::jsonb
  );

  select gym_id into v_gym_id
  from public.profiles
  where id = v_user_id;

  perform set_config('app.allow_billing_update', '1', true);
  update public.gyms
  set
    plan_code = 'pro',
    subscription_status = 'active',
    current_period_end = now() + interval '10 days',
    billing_provider = 'toss',
    billing_customer_id = 'p1_16_customer',
    auto_renew = true
  where id = v_gym_id;
  perform set_config('app.allow_billing_update', '0', true);

  begin
    execute 'set local role authenticated';
    insert into public.payment_attempts (
      gym_id,
      provider,
      payment_type,
      amount_krw,
      order_id
    )
    values (v_gym_id, 'toss', 'auto_renewal', 10000, 'p1_16_client_write');
    execute 'reset role';
    insert into p1_16_privilege_results (test_name, status, detail)
    values ('owner role cannot insert a payment attempt', 'FAIL', 'statement succeeded');
  exception
    when insufficient_privilege then
      execute 'reset role';
      insert into p1_16_privilege_results (test_name, status, detail)
      values (
        'owner role cannot insert a payment attempt',
        case when sqlerrm ilike '%permission denied%' then 'PASS' else 'FAIL' end,
        sqlerrm
      );
    when others then
      execute 'reset role';
      insert into p1_16_privilege_results (test_name, status, detail)
      values ('owner role cannot insert a payment attempt', 'FAIL', sqlstate);
  end;

  begin
    execute 'set local role anon';
    update public.gyms
    set name = 'renamed by client'
    where id = v_gym_id;
    execute 'reset role';
    insert into p1_16_privilege_results (test_name, status, detail)
    values ('anon cannot update a gym', 'FAIL', 'statement succeeded');
  exception
    when insufficient_privilege then
      execute 'reset role';
      insert into p1_16_privilege_results (test_name, status, detail)
      values (
        'anon cannot update a gym',
        case when sqlerrm ilike '%permission denied%' then 'PASS' else 'FAIL' end,
        sqlerrm
      );
    when others then
      execute 'reset role';
      insert into p1_16_privilege_results (test_name, status, detail)
      values ('anon cannot update a gym', 'FAIL', sqlstate);
  end;

  begin
    execute 'set local role service_role';
    insert into public.payment_attempts (
      gym_id,
      provider,
      payment_type,
      amount_krw,
      order_id
    )
    values (v_gym_id, 'toss', 'auto_renewal', 10000, 'p1_16_server_write');
    update public.gyms
    set subscription_status = 'past_due'
    where id = v_gym_id;
    execute 'reset role';

    select g.subscription_status into v_status
    from public.gyms g
    where g.id = v_gym_id;

    insert into p1_16_privilege_results (test_name, status, detail)
    values (
      'service role can write payment rows and billing status',
      case
        when v_status = 'past_due'
         and exists (
           select 1
           from public.payment_attempts pa
           where pa.order_id = 'p1_16_server_write'
         )
        then 'PASS'
        else 'FAIL'
      end,
      coalesce(v_status, 'missing')
    );
  exception
    when others then
      execute 'reset role';
      insert into p1_16_privilege_results (test_name, status, detail)
      values (
        'service role can write payment rows and billing status',
        'FAIL',
        sqlstate
      );
  end;

  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role authenticated';
  v_result := public.cancel_gym_subscription();
  execute 'reset role';

  select g.subscription_status into v_status
  from public.gyms g
  where g.id = v_gym_id;

  insert into p1_16_privilege_results (test_name, status, detail)
  values (
    'owner cancel path still updates billing status',
    case
      when v_result->>'ok' = 'true' and v_status = 'canceled' then 'PASS'
      else 'FAIL'
    end,
    coalesce(v_status, 'missing')
  );
exception
  when others then
    execute 'reset role';
    insert into p1_16_privilege_results (test_name, status, detail)
    values ('payment privilege scenario', 'FAIL', sqlstate || ' ' || sqlerrm);
end;
$$;

select test_name, status, detail
from p1_16_privilege_results
order by test_name;

rollback;
