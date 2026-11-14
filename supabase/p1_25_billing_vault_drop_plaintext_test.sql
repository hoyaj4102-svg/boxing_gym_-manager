-- Synthetic column-drop checks. This script rolls back.
-- Keys below are fixtures, not live billing keys.

begin;

create temp table p1_25_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

insert into p1_25_results (test_name, status, detail)
select
  'plaintext billing column is dropped',
  case
    when not exists (
      select 1
      from information_schema.columns
      where table_schema = 'private'
        and table_name = 'billing_credentials'
        and column_name = 'billing_key'
    )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into public.gyms (
  id, name, plan_code, member_limit, subscription_status,
  billing_provider, billing_customer_id, auto_renew
)
values (
  '00000000-0000-4000-8000-000000000251',
  '__p1_25_vault__',
  'pro',
  -1,
  'active',
  'toss',
  'synthetic-p125-customer',
  false
);

select public.upsert_gym_billing_credential(
  '00000000-0000-4000-8000-000000000251',
  'synthetic-vault-key-drop',
  'toss'
);

insert into p1_25_results (test_name, status, detail)
select
  'charge read uses the vault key',
  case
    when public.read_gym_billing_credential(
      '00000000-0000-4000-8000-000000000251'
    ) = 'synthetic-vault-key-drop'
     and public.read_gym_billing_vault_credential(
      '00000000-0000-4000-8000-000000000251'
    ) = 'synthetic-vault-key-drop'
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

select set_config('app.allow_billing_update', '1', true);

update public.gyms
set billing_subscription_id = 'synthetic-subscription-ref'
where id = '00000000-0000-4000-8000-000000000251';

insert into p1_25_results (test_name, status, detail)
select
  'gyms column is not the charge key after retirement',
  case
    when public.read_gym_billing_credential(
      '00000000-0000-4000-8000-000000000251'
    ) = 'synthetic-vault-key-drop'
     and exists (
       select 1
       from public.gyms
       where id = '00000000-0000-4000-8000-000000000251'
         and billing_subscription_id = 'synthetic-subscription-ref'
     )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

do $$
declare
  v_message text;
  v_still_there boolean;
begin
  alter table private.billing_credentials add column billing_key text;
  update private.billing_credentials
  set billing_key = 'synthetic-vault-key-not-copied'
  where gym_id = '00000000-0000-4000-8000-000000000251';

  begin
    perform private.drop_billing_plaintext_column();
    v_message := 'call returned';
  exception
    when others then
      v_message := sqlerrm;
  end;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_still_there;

  insert into p1_25_results (test_name, status, detail)
  values (
    'drop refuses leftover plaintext',
    case
      when v_message = 'BILLING_VAULT_PLAINTEXT_REMAINS'
       and position('synthetic-vault-key-not-copied' in v_message) = 0
       and v_still_there
      then 'PASS'
      else 'FAIL'
    end,
    'refused'
  );

  update private.billing_credentials
  set billing_key = null
  where gym_id = '00000000-0000-4000-8000-000000000251';
  perform private.drop_billing_plaintext_column();
end;
$$;

do $$
declare
  v_value text;
begin
  perform private.rollback_billing_vault_drop();

  select billing_key
  into v_value
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000251';

  insert into p1_25_results (test_name, status, detail)
  values (
    'drop rollback restores plaintext from vault',
    case
      when v_value = 'synthetic-vault-key-drop'
       and private.billing_vault_plaintext_retired()
      then 'PASS'
      else 'FAIL'
    end,
    'compared'
  );
exception
  when others then
    insert into p1_25_results (test_name, status, detail)
    values ('drop rollback restores plaintext from vault', 'FAIL', sqlstate);
end;
$$;

do $$
begin
  begin
    execute 'set local role authenticated';
    execute 'select decrypted_secret from vault.decrypted_secrets';
    execute 'reset role';
    insert into p1_25_results (test_name, status, detail)
    values ('authenticated cannot read vault', 'FAIL', 'statement succeeded');
  exception
    when insufficient_privilege then
      execute 'reset role';
      insert into p1_25_results (test_name, status, detail)
      values ('authenticated cannot read vault', 'PASS', 'permission denied');
    when others then
      execute 'reset role';
      insert into p1_25_results (test_name, status, detail)
      values ('authenticated cannot read vault', 'FAIL', sqlstate);
  end;
end;
$$;

select test_name, status, detail
from p1_25_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_25_results where status <> 'PASS') then
    raise exception 'P1_25_VAULT_DROP_TESTS_FAILED';
  end if;
end;
$$;

rollback;
