-- Synthetic plaintext-clear checks. This script rolls back.
-- Keys below are fixtures, not live billing keys.

begin;

create temp table p1_24_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

alter table private.billing_credentials
  add column if not exists billing_key text;

alter table private.billing_credentials
  alter column billing_key drop not null;

insert into public.gyms (
  id, name, plan_code, member_limit, subscription_status,
  billing_provider, billing_customer_id, billing_subscription_id, auto_renew
)
values
  (
    '00000000-0000-4000-8000-000000000241',
    '__p1_24_unvaulted__',
    'pro',
    -1,
    'active',
    'toss',
    'synthetic-p124-customer-u',
    'synthetic-subscription-ref',
    false
  ),
  (
    '00000000-0000-4000-8000-000000000242',
    '__p1_24_confirmed__',
    'pro',
    -1,
    'active',
    'toss',
    'synthetic-p124-customer-c',
    'synthetic-vault-key-c',
    false
  );

insert into private.billing_credentials (gym_id, provider, billing_key)
values (
  '00000000-0000-4000-8000-000000000241',
  'toss',
  'synthetic-vault-key-unvaulted'
);

insert into public.payment_attempts (
  gym_id, provider, payment_type, billing_interval, amount_krw, currency,
  order_id, billing_key_ref, status, activation_status, recovery_status
)
values
  (
    '00000000-0000-4000-8000-000000000241',
    'toss',
    'initial_billing',
    'monthly',
    10000,
    'KRW',
    'synthetic-p124-unmatched-order',
    'synthetic-attempt-not-in-vault',
    'completed',
    'succeeded',
    'none'
  );

select private.clear_vault_confirmed_billing_plaintext();

do $$
declare
  v_message text;
  v_kept text;
begin
  select billing_key
  into v_kept
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000241';

  begin
    perform private.assert_billing_plaintext_vaulted();
    v_message := 'call returned';
  exception
    when others then
      v_message := sqlerrm;
  end;

  insert into p1_24_results (test_name, status, detail)
  values (
    'clear skips values that are not in vault',
    case
      when v_kept = 'synthetic-vault-key-unvaulted'
       and exists (
         select 1
         from public.gyms
         where id = '00000000-0000-4000-8000-000000000241'
           and billing_subscription_id = 'synthetic-subscription-ref'
       )
       and exists (
         select 1
         from public.payment_attempts
         where order_id = 'synthetic-p124-unmatched-order'
           and billing_key_ref = 'synthetic-attempt-not-in-vault'
       )
      then 'PASS'
      else 'FAIL'
    end,
    'compared'
  );

  insert into p1_24_results (test_name, status, detail)
  values (
    'assert refuses an unvaulted charge key without echoing it',
    case
      when v_message = 'BILLING_VAULT_PLAINTEXT_NOT_VAULTED'
       and position('synthetic-vault-key-unvaulted' in v_message) = 0
       and v_kept = 'synthetic-vault-key-unvaulted'
      then 'PASS'
      else 'FAIL'
    end,
    'refused'
  );
end;
$$;

insert into private.billing_credentials (gym_id, provider, billing_key)
values (
  '00000000-0000-4000-8000-000000000242',
  'toss',
  'synthetic-vault-key-c'
);

insert into public.subscriptions (
  gym_id, plan_code, status, provider, provider_ref, amount_krw, started_at
)
values
  (
    '00000000-0000-4000-8000-000000000242',
    'pro',
    'active',
    'toss',
    'synthetic-payment-ref',
    10000,
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000242',
    'pro',
    'active',
    'toss',
    'synthetic-vault-key-c',
    10000,
    now()
  ),
  (
    '00000000-0000-4000-8000-000000000241',
    'pro',
    'active',
    'toss',
    'synthetic-unrelated-provider-ref',
    10000,
    now()
  );

insert into public.payment_attempts (
  gym_id, provider, payment_type, billing_interval, amount_krw, currency,
  order_id, billing_key_ref, status, activation_status, recovery_status
)
values (
  '00000000-0000-4000-8000-000000000242',
  'toss',
  'initial_billing',
  'monthly',
  10000,
  'KRW',
  'synthetic-p124-matched-order',
  'synthetic-vault-key-c',
  'completed',
  'succeeded',
  'none'
);

select private.copy_billing_keys_to_vault();
select private.clear_vault_confirmed_billing_plaintext();

insert into p1_24_results (test_name, status, detail)
select
  'clear nulls only vault-confirmed secrets',
  case
    when exists (
      select 1
      from private.billing_credentials c
      where c.gym_id = '00000000-0000-4000-8000-000000000242'
        and c.billing_key is null
    )
     and private.read_gym_vault_billing_key(
       '00000000-0000-4000-8000-000000000242', 'toss'
     ) = 'synthetic-vault-key-c'
     and exists (
       select 1
       from public.gyms
       where id = '00000000-0000-4000-8000-000000000242'
         and billing_subscription_id is null
     )
     and exists (
       select 1
       from public.gyms
       where id = '00000000-0000-4000-8000-000000000241'
         and billing_subscription_id = 'synthetic-subscription-ref'
     )
     and exists (
       select 1
       from public.payment_attempts
       where order_id = 'synthetic-p124-matched-order'
         and billing_key_ref is null
     )
     and exists (
       select 1
       from public.payment_attempts
       where order_id = 'synthetic-p124-unmatched-order'
         and billing_key_ref = 'synthetic-attempt-not-in-vault'
     )
     and exists (
       select 1
       from public.subscriptions
       where gym_id = '00000000-0000-4000-8000-000000000242'
         and provider_ref = 'synthetic-payment-ref'
     )
     and exists (
       select 1
       from public.subscriptions
       where gym_id = '00000000-0000-4000-8000-000000000242'
         and provider_ref is null
     )
     and exists (
       select 1
       from public.subscriptions
       where gym_id = '00000000-0000-4000-8000-000000000241'
         and provider_ref = 'synthetic-unrelated-provider-ref'
     )
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

insert into p1_24_results (test_name, status, detail)
select
  'retired reads do not use the gyms column',
  case
    when private.billing_vault_plaintext_retired()
     and public.read_gym_billing_credential(
       '00000000-0000-4000-8000-000000000241'
     ) = 'synthetic-vault-key-unvaulted'
     and public.read_gym_billing_credential(
       '00000000-0000-4000-8000-000000000242'
     ) = 'synthetic-vault-key-c'
    then 'PASS'
    else 'FAIL'
  end,
  'compared';

-- A Vault secret that does not match plaintext must abort the backfill.
-- The exception subtransaction undoes that attempt and leaves the fixture key.
do $$
declare
  v_message text;
  v_kept text;
  v_secret_id uuid;
begin
  insert into public.gyms (
    id, name, plan_code, member_limit, subscription_status,
    billing_provider, billing_customer_id, auto_renew
  )
  values (
    '00000000-0000-4000-8000-000000000243',
    '__p1_24_mismatch__',
    'pro',
    -1,
    'active',
    'toss',
    'synthetic-p124-customer-m',
    false
  );

  insert into private.billing_credentials (gym_id, provider, billing_key)
  values (
    '00000000-0000-4000-8000-000000000243',
    'toss',
    'synthetic-vault-key-plain'
  );

  v_secret_id := vault.create_secret(
    'synthetic-vault-key-other',
    'billing_key:00000000-0000-4000-8000-000000000243:toss',
    'billing credential'
  );

  insert into private.billing_vault_secrets (gym_id, provider, secret_id, source)
  values (
    '00000000-0000-4000-8000-000000000243',
    'toss',
    v_secret_id,
    'billing_credentials'
  );

  begin
    perform private.backfill_billing_credentials();
    v_message := 'call returned';
  exception
    when others then
      v_message := sqlerrm;
  end;

  select billing_key
  into v_kept
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000243';

  insert into p1_24_results (test_name, status, detail)
  values (
    'backfill refuses a vault value that does not match',
    case
      when v_message = 'BILLING_VAULT_COPY_MISMATCH'
       and position('synthetic-vault-key-plain' in v_message) = 0
       and position('synthetic-vault-key-other' in v_message) = 0
       and v_kept = 'synthetic-vault-key-plain'
      then 'PASS'
      else 'FAIL'
    end,
    'refused'
  );
end;
$$;

do $$
declare
  v_restored text;
  v_retired boolean;
begin
  perform private.rollback_billing_vault_clear();

  select billing_key
  into v_restored
  from private.billing_credentials
  where gym_id = '00000000-0000-4000-8000-000000000242';

  select retire_plaintext
  into v_retired
  from private.billing_vault_policy
  where id = 1;

  insert into p1_24_results (test_name, status, detail)
  values (
    'clear rollback restores confirmed plaintext',
    case
      when v_restored = 'synthetic-vault-key-c'
       and v_retired = false
       and exists (
         select 1
         from public.gyms
         where id = '00000000-0000-4000-8000-000000000242'
           and billing_subscription_id = 'synthetic-vault-key-c'
       )
       and exists (
         select 1
         from public.payment_attempts
         where order_id = 'synthetic-p124-matched-order'
           and billing_key_ref = 'synthetic-vault-key-c'
       )
       and private.read_gym_vault_billing_key(
         '00000000-0000-4000-8000-000000000242', 'toss'
       ) = 'synthetic-vault-key-c'
      then 'PASS'
      else 'FAIL'
    end,
    'compared'
  );
exception
  when others then
    insert into p1_24_results (test_name, status, detail)
    values ('clear rollback restores confirmed plaintext', 'FAIL', sqlstate);
end;
$$;

select test_name, status, detail
from p1_24_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_24_results where status <> 'PASS') then
    raise exception 'P1_24_VAULT_CLEAR_TESTS_FAILED';
  end if;
end;
$$;

rollback;
