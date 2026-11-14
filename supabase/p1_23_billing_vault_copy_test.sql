-- Synthetic Vault copy checks. This script rolls back.
-- Keys below are fixtures, not live billing keys.

begin;

create temp table p1_23_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

alter table private.billing_credentials
  add column if not exists billing_key text;

update private.billing_vault_policy
set retire_plaintext = false
where id = 1;

insert into public.gyms (
  id, name, plan_code, member_limit, subscription_status,
  billing_provider, billing_customer_id, billing_subscription_id, auto_renew
)
values
  (
    '00000000-0000-4000-8000-000000000023',
    '__p1_23_private__',
    'pro',
    -1,
    'active',
    'toss',
    'synthetic-p123-customer-a',
    null,
    false
  ),
  (
    '00000000-0000-4000-8000-000000000024',
    '__p1_23_fallback__',
    'pro',
    -1,
    'active',
    'toss',
    'synthetic-p123-customer-b',
    'synthetic-vault-key-b',
    false
  );

insert into private.billing_credentials (gym_id, provider, billing_key)
values (
  '00000000-0000-4000-8000-000000000023',
  'toss',
  'synthetic-vault-key-a'
);

select private.copy_billing_keys_to_vault();

insert into p1_23_results (test_name, status, detail)
select
  'copy keeps plaintext and matches vault',
  case
    when private.read_gym_vault_billing_key(
      '00000000-0000-4000-8000-000000000023', 'toss'
    ) = 'synthetic-vault-key-a'
     and exists (
       select 1
       from private.billing_credentials c
       where c.gym_id = '00000000-0000-4000-8000-000000000023'
         and c.billing_key = 'synthetic-vault-key-a'
         and c.vault_secret_id is not null
     )
     and private.read_gym_vault_billing_key(
       '00000000-0000-4000-8000-000000000024', 'toss'
     ) = 'synthetic-vault-key-b'
     and exists (
       select 1
       from public.gyms g
       where g.id = '00000000-0000-4000-8000-000000000024'
         and g.billing_subscription_id = 'synthetic-vault-key-b'
     )
     and not exists (
       select 1
       from private.billing_credentials c
       where c.gym_id = '00000000-0000-4000-8000-000000000024'
     )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into p1_23_results (test_name, status, detail)
select
  'gyms fallback still resolves before plaintext retirement',
  case
    when public.read_gym_billing_credential(
      '00000000-0000-4000-8000-000000000024'
    ) = 'synthetic-vault-key-b'
     and public.read_gym_billing_vault_credential(
      '00000000-0000-4000-8000-000000000023'
    ) = 'synthetic-vault-key-a'
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

create temp table p1_23_secret_count on commit drop as
select count(*)::integer as secret_count
from vault.secrets
where name like 'billing_key:%';

select private.copy_billing_keys_to_vault();

insert into p1_23_results (test_name, status, detail)
select
  'copy is idempotent',
  case
    when (
      select count(*)::integer
      from vault.secrets
      where name like 'billing_key:%'
    ) = (select secret_count from p1_23_secret_count)
     and (
       select count(*)::integer
       from private.billing_vault_secrets
       where gym_id in (
         '00000000-0000-4000-8000-000000000023',
         '00000000-0000-4000-8000-000000000024'
       )
     ) = 2
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

do $$
declare
  v_message text;
  v_plain text;
begin
  update private.billing_credentials
  set billing_key = 'synthetic-vault-key-a'
  where gym_id = '00000000-0000-4000-8000-000000000023';

  begin
    perform vault.update_secret(
      (
        select secret_id
        from private.billing_vault_secrets
        where gym_id = '00000000-0000-4000-8000-000000000023'
      ),
      'synthetic-vault-key-mismatch',
      'billing_key:00000000-0000-4000-8000-000000000023:toss',
      'billing credential'
    );
    perform private.copy_billing_keys_to_vault();
    v_message := 'call returned';
  exception
    when others then
      v_message := sqlerrm;
  end;

  select billing_key
  into v_plain
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000023';

  insert into p1_23_results (test_name, status, detail)
  values (
    'mismatch aborts and does not echo the key',
    case
      when v_message = 'BILLING_VAULT_COPY_MISMATCH'
       and position('synthetic-vault-key-a' in v_message) = 0
       and position('synthetic-vault-key-mismatch' in v_message) = 0
       and v_plain = 'synthetic-vault-key-a'
       and (
         select count(*)
         from vault.secrets
         where name = 'billing_key:00000000-0000-4000-8000-000000000023:toss'
       ) = 1
      then 'PASS'
      else 'FAIL'
    end,
    'aborted'
  );
end;
$$;

do $$
declare
  v_name text;
  v_sql text;
begin
  for v_name, v_sql in
    select *
    from (values
      (
        'anon cannot read vault secrets',
        'select decrypted_secret from vault.decrypted_secrets'
      ),
      (
        'anon cannot call vault decrypt',
        'select private.read_billing_vault_secret(null)'
      ),
      (
        'authenticated cannot call vault credential read',
        'select public.read_gym_billing_vault_credential(null)'
      ),
      (
        'anon cannot create a vault secret',
        'select vault.create_secret(''synthetic-should-not-store'', null, '''')'
      )
    ) as checks(test_name, statement)
  loop
    begin
      if v_name like 'authenticated%' then
        execute 'set local role authenticated';
      else
        execute 'set local role anon';
      end if;
      execute v_sql;
      execute 'reset role';
      insert into p1_23_results (test_name, status, detail)
      values (v_name, 'FAIL', 'statement succeeded');
    exception
      when insufficient_privilege then
        execute 'reset role';
        insert into p1_23_results (test_name, status, detail)
        values (v_name, 'PASS', 'permission denied');
      when others then
        execute 'reset role';
        insert into p1_23_results (test_name, status, detail)
        values (v_name, 'FAIL', sqlstate);
    end;
  end loop;
end;
$$;

do $$
declare
  v_actual text;
  v_expected text := 'synthetic-vault-key-a';
begin
  execute 'set local role service_role';
  select public.read_gym_billing_vault_credential(
    '00000000-0000-4000-8000-000000000023'
  )
  into v_actual;
  execute 'reset role';

  insert into p1_23_results (test_name, status, detail)
  values (
    'service role reads the vault key',
    case when v_actual = v_expected then 'PASS' else 'FAIL' end,
    'compared'
  );
exception
  when others then
    execute 'reset role';
    insert into p1_23_results (test_name, status, detail)
    values ('service role reads the vault key', 'FAIL', sqlstate);
end;
$$;

do $$
declare
  v_plain text;
  v_secrets integer;
begin
  perform private.rollback_billing_vault_copy();

  select billing_key
  into v_plain
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000023';

  select count(*)
  into v_secrets
  from private.billing_vault_secrets
  where gym_id in (
    '00000000-0000-4000-8000-000000000023',
    '00000000-0000-4000-8000-000000000024'
  );

  insert into p1_23_results (test_name, status, detail)
  values (
    'rollback removes vault copies and keeps plaintext',
    case
      when v_plain = 'synthetic-vault-key-a'
       and v_secrets = 0
       and exists (
         select 1
         from public.gyms
         where id = '00000000-0000-4000-8000-000000000024'
           and billing_subscription_id = 'synthetic-vault-key-b'
       )
      then 'PASS'
      else 'FAIL'
    end,
    'compared'
  );
exception
  when others then
    insert into p1_23_results (test_name, status, detail)
    values ('rollback removes vault copies and keeps plaintext', 'FAIL', sqlstate);
end;
$$;

select test_name, status, detail
from p1_23_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_23_results where status <> 'PASS') then
    raise exception 'P1_23_VAULT_COPY_TESTS_FAILED';
  end if;
end;
$$;

rollback;
