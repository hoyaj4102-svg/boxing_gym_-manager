-- Synthetic Vault checks for p1_31. This script rolls back.
-- It does not read production data and does not call a payment provider.

begin;

create temp table p1_31_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_31_context (
  primary_gym_id uuid not null,
  fallback_gym_id uuid not null,
  mismatch_gym_id uuid not null,
  primary_key text not null,
  fallback_key text not null,
  kept_ref text not null,
  other_ref text not null
) on commit drop;

insert into p1_31_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  'synthetic-vault-card-key',
  'synthetic-vault-fallback-key',
  'synthetic-vault-card-key',
  'synthetic-unrelated-ref'
);

select set_config('app.allow_billing_update', '1', true);

insert into public.gyms (id, name, billing_provider, billing_subscription_id)
select primary_gym_id, 'Synthetic Vault Primary', 'toss', 'synthetic-subscription-ref'
from p1_31_context
union all
select fallback_gym_id, 'Synthetic Vault Fallback', 'toss', fallback_key
from p1_31_context
union all
select mismatch_gym_id, 'Synthetic Vault Mismatch', 'toss', null::text
from p1_31_context;

alter table private.billing_credentials disable trigger billing_credentials_vault_key;

insert into private.billing_credentials (gym_id, provider, billing_key)
select primary_gym_id, 'toss', primary_key
from p1_31_context;

insert into public.payment_attempts (
  gym_id, provider, payment_type, amount_krw, order_id, billing_key_ref, status
)
select primary_gym_id, 'toss', 'auto_renewal', 10000, 'synthetic-vault-order-match', kept_ref, 'initiated'
from p1_31_context
union all
select primary_gym_id, 'toss', 'auto_renewal', 10000, 'synthetic-vault-order-keep', other_ref, 'initiated'
from p1_31_context;

alter table private.billing_credentials enable trigger billing_credentials_vault_key;

select private.copy_billing_keys_to_vault();

insert into p1_31_results (test_name, status, detail)
select
  'existing credential is copied and the plaintext column stays',
  case
    when c.billing_key = ctx.primary_key
     and c.vault_secret_id is not null
     and o.source = 'billing_credentials'
     and private.read_billing_vault_secret(c.vault_secret_id) = ctx.primary_key
     and public.read_gym_billing_vault_credential(ctx.primary_gym_id) = ctx.primary_key
     and g.billing_subscription_id = 'synthetic-subscription-ref'
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_context ctx
join private.billing_credentials c
  on c.gym_id = ctx.primary_gym_id
 and c.provider = 'toss'
join private.billing_vault_origins o
  on o.gym_id = ctx.primary_gym_id
 and o.provider = 'toss'
join public.gyms g on g.id = ctx.primary_gym_id;

insert into p1_31_results (test_name, status, detail)
select
  'gym fallback is copied without clearing that column',
  case
    when g.billing_subscription_id = ctx.fallback_key
     and c.billing_key = ctx.fallback_key
     and o.source = 'gyms_fallback'
     and public.read_gym_billing_vault_credential(ctx.fallback_gym_id) = ctx.fallback_key
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_context ctx
join public.gyms g on g.id = ctx.fallback_gym_id
join private.billing_credentials c
  on c.gym_id = ctx.fallback_gym_id
 and c.provider = 'toss'
join private.billing_vault_origins o
  on o.gym_id = ctx.fallback_gym_id
 and o.provider = 'toss';

insert into p1_31_results (test_name, status, detail)
select
  'attempt references stay in place',
  case
    when matched.billing_key_ref = ctx.kept_ref
     and kept.billing_key_ref = ctx.other_ref
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_context ctx
join public.payment_attempts matched
  on matched.order_id = 'synthetic-vault-order-match'
join public.payment_attempts kept
  on kept.order_id = 'synthetic-vault-order-keep';

create temp table p1_31_secret_ids on commit drop as
select c.gym_id, c.vault_secret_id
from private.billing_credentials c
join p1_31_context ctx on c.gym_id in (ctx.primary_gym_id, ctx.fallback_gym_id);

select private.copy_billing_keys_to_vault();

insert into p1_31_results (test_name, status, detail)
select
  'a second copy does not create another secret',
  case
    when count(*) = 2
     and count(*) = count(c.vault_secret_id)
     and bool_and(c.vault_secret_id = saved.vault_secret_id)
     and bool_and(c.billing_key is not null)
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_secret_ids saved
join private.billing_credentials c
  on c.gym_id = saved.gym_id
 and c.provider = 'toss';

insert into private.billing_credentials (gym_id, provider, billing_key)
select primary_gym_id, 'stripe', 'synthetic-vault-stripe-key'
from p1_31_context;

insert into p1_31_results (test_name, status, detail)
select
  'a new write keeps plaintext and adds a vault reference',
  case
    when c.billing_key = 'synthetic-vault-stripe-key'
     and private.read_billing_vault_secret(c.vault_secret_id) = 'synthetic-vault-stripe-key'
     and public.read_gym_billing_vault_credential(ctx.primary_gym_id) = ctx.primary_key
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_context ctx
join private.billing_credentials c
  on c.gym_id = ctx.primary_gym_id
 and c.provider = 'stripe';

do $mismatch$
declare
  v_gym uuid;
  v_name text;
  v_message text;
begin
  select mismatch_gym_id into v_gym from p1_31_context;
  v_name := 'billing_key:' || v_gym::text || ':toss';

  alter table private.billing_credentials disable trigger billing_credentials_vault_key;
  insert into private.billing_credentials (gym_id, provider, billing_key)
  values (v_gym, 'toss', 'synthetic-vault-plain');
  perform vault.create_secret('synthetic-vault-other', v_name, 'billing credential');
  alter table private.billing_credentials enable trigger billing_credentials_vault_key;

  begin
    perform private.copy_billing_keys_to_vault();
    v_message := 'call returned';
  exception when others then
    v_message := sqlerrm;
  end;

  insert into p1_31_results (test_name, status, detail)
  values (
    'a different existing secret aborts before clearing plaintext',
    case
      when v_message = 'BILLING_VAULT_COPY_MISMATCH'
       and exists (
         select 1
         from private.billing_credentials c
         where c.gym_id = v_gym
           and c.billing_key = 'synthetic-vault-plain'
       )
      then 'PASS' else 'FAIL'
    end,
    case when v_message = 'BILLING_VAULT_COPY_MISMATCH' then 'aborted' else 'not aborted' end
  );

  delete from private.billing_credentials where gym_id = v_gym;
  delete from vault.secrets where name = v_name;
  delete from public.gyms where id = v_gym;
end
$mismatch$;

create or replace function pg_temp.p1_31_call_state(p_role text, p_sql text)
returns text
language plpgsql
set search_path = pg_catalog
as $call_state$
begin
  execute format('set local role %I', p_role);
  execute p_sql;
  execute 'reset role';
  return 'call returned';
exception when others then
  execute 'reset role';
  return sqlstate;
end;
$call_state$;

revoke all on function pg_temp.p1_31_call_state(text, text) from public;

grant usage on schema private to postgres_migrator;
grant execute on function private.current_role_can_revoke(oid, aclitem[]) to postgres_migrator;
grant execute on function private.revoke_hosted_vault_privileges() to postgres_migrator;

insert into p1_31_results (test_name, status, detail)
select
  'anon and authenticated cannot read the vault billing key',
  case
    when pg_temp.p1_31_call_state(
      'anon',
      'select public.read_gym_billing_vault_credential(null)'
    ) = '42501'
     and pg_temp.p1_31_call_state(
      'authenticated',
      'select public.read_gym_billing_vault_credential(null)'
    ) = '42501'
     and pg_temp.p1_31_call_state(
      'anon',
      'select decrypted_secret from vault.decrypted_secrets'
    ) = '42501'
     and pg_temp.p1_31_call_state(
      'authenticated',
      'select billing_key from private.billing_credentials'
    ) = '42501'
     and has_function_privilege(
      'anon',
      'public.read_gym_billing_vault_credential(uuid)',
      'execute'
    ) = false
     and has_function_privilege(
      'authenticated',
      'private.read_billing_vault_secret(uuid)',
      'execute'
    ) = false
    then 'PASS' else 'FAIL'
  end,
  'denied';

insert into p1_31_results (test_name, status, detail)
select
  'service role reads through the definer function',
  case
    when pg_temp.p1_31_call_state(
      'service_role',
      format(
        'select 1 where public.read_gym_billing_vault_credential(%L) = %L',
        primary_gym_id,
        primary_key
      )
    ) = 'call returned'
     and has_table_privilege(
      'service_role',
      'vault.decrypted_secrets',
      'select'
    )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_31_context;

insert into p1_31_results (test_name, status, detail)
select
  'hosted vault ownership does not fail the revoke',
  case
    when pg_catalog.pg_get_userbyid(p.proowner) = 'supabase_admin'
     and has_table_privilege(
      'service_role',
      'vault.decrypted_secrets',
      'select'
    )
     and pg_temp.p1_31_call_state(
      'postgres_migrator',
      'do $r$ begin perform private.revoke_hosted_vault_privileges(); end $r$'
    ) = 'call returned'
     and has_table_privilege(
      'service_role',
      'vault.decrypted_secrets',
      'select'
    )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from pg_catalog.pg_proc p
join pg_catalog.pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'vault'
  and p.proname = '_crypto_aead_det_noncegen';

insert into p1_31_results (test_name, status, detail)
select
  'prebackup table is owner-only and has no vault id',
  case
    when c.relrowsecurity
     and not exists (
       select 1
       from information_schema.columns col
       where col.table_schema = 'private'
         and col.table_name = 'billing_credentials_backup_20261125'
         and col.column_name = 'vault_secret_id'
     )
     and exists (
       select 1
       from information_schema.columns col
       where col.table_schema = 'private'
         and col.table_name = 'billing_credentials_backup_20261125'
         and col.column_name = 'billing_key'
     )
     and not has_table_privilege(
      'anon',
      'private.billing_credentials_backup_20261125',
      'select'
    )
     and not has_table_privilege(
      'authenticated',
      'private.billing_credentials_backup_20261125',
      'select'
    )
     and not has_table_privilege(
      'service_role',
      'private.billing_credentials_backup_20261125',
      'select'
    )
    then 'PASS' else 'FAIL'
  end,
  'compared'
from pg_catalog.pg_class c
join pg_catalog.pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'private'
  and c.relname = 'billing_credentials_backup_20261125';

insert into p1_31_results (test_name, status, detail)
select
  'vault read function pins an empty search path',
  case
    when exists (
      select 1
      from pg_catalog.pg_proc p
      cross join lateral unnest(coalesce(p.proconfig, array[]::text[])) as cfg
      where p.oid = 'private.read_billing_vault_secret(uuid)'::regprocedure
        and cfg = 'search_path=""'
    )
     and exists (
      select 1
      from pg_catalog.pg_proc p
      cross join lateral unnest(coalesce(p.proconfig, array[]::text[])) as cfg
      where p.oid = 'public.read_gym_billing_vault_credential(uuid)'::regprocedure
        and cfg = 'search_path=""'
    )
    then 'PASS' else 'FAIL'
  end,
  'compared';

select private.rollback_billing_keys_from_vault();

insert into p1_31_results (test_name, status, detail)
select
  'rollback removes the vault copies and leaves plaintext',
  case
    when c.billing_key = ctx.primary_key
     and c.vault_secret_id is null
     and g.billing_subscription_id = 'synthetic-subscription-ref'
     and fallback.billing_subscription_id = ctx.fallback_key
     and not exists (
       select 1
       from private.billing_credentials removed
       where removed.gym_id = ctx.fallback_gym_id
     )
     and matched.billing_key_ref = ctx.kept_ref
     and kept.billing_key_ref = ctx.other_ref
     and not exists (select 1 from private.billing_vault_origins)
     and not exists (
       select 1
       from vault.secrets s
       where s.name = 'billing_key:' || ctx.primary_gym_id::text || ':toss'
          or s.name = 'billing_key:' || ctx.fallback_gym_id::text || ':toss'
     )
    then 'PASS' else 'FAIL'
  end,
  'restored'
from p1_31_context ctx
join private.billing_credentials c
  on c.gym_id = ctx.primary_gym_id
 and c.provider = 'toss'
join public.gyms g on g.id = ctx.primary_gym_id
join public.gyms fallback on fallback.id = ctx.fallback_gym_id
join public.payment_attempts matched
  on matched.order_id = 'synthetic-vault-order-match'
join public.payment_attempts kept
  on kept.order_id = 'synthetic-vault-order-keep';

select test_name, status, detail
from p1_31_results
order by test_name;

rollback;
