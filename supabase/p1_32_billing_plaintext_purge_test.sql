-- Synthetic checks for p1_32_billing_plaintext_purge_once.sql and its
-- rollback. Runs both files verbatim on fake rows. This script rolls back.
-- It does not read production data and does not call a payment provider.
-- The fake rows have the same shape as the counts in the purge file:
-- 3 credentials (1 original, 2 copied from the gym fallback), 1 backup row,
-- 3 toss gyms with a fallback value (1 differs from its Vault key),
-- 3 attempt references (1 equals that differing value), 0 checkout rows.

\set purge_sql `cat supabase/p1_32_billing_plaintext_purge_once.sql`
\set restore_sql `cat supabase/p1_32_billing_plaintext_purge_rollback.sql`

begin;

select set_config('p1_32.purge_sql', :'purge_sql', true) is not null as purge_loaded \gset
select set_config('p1_32.restore_sql', :'restore_sql', true) is not null as restore_loaded \gset

create temp table p1_32_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_32_context (
  gym_a uuid not null,
  gym_b uuid not null,
  gym_c uuid not null,
  gym_d uuid not null,
  gym_e uuid not null,
  gym_f uuid not null,
  key_a text not null,
  legacy_a text not null,
  key_b text not null,
  key_c text not null
) on commit drop;

insert into p1_32_context
values (
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  gen_random_uuid(), gen_random_uuid(), gen_random_uuid(),
  'p132-fake-cred-a',
  'synthetic-p132-legacy-a',
  'p132-fake-cred-b',
  'p132-fake-cred-c'
);

-- Runs SQL text and returns 'OK' or the error message. An error rolls back
-- everything the text did.
create function pg_temp.p1_32_try(p_sql text)
returns text
language plpgsql
as $try$
begin
  execute p_sql;
  return 'OK';
exception
  when others then
    return sqlerrm;
end;
$try$;

-- Counts only. Used to prove a failed run changed nothing.
create function pg_temp.p1_32_state()
returns text
language plpgsql
as $state$
declare
  v_backup text := 'missing';
begin
  if to_regclass('private.billing_credentials_backup_20261125') is not null then
    execute 'select count(*)::text from private.billing_credentials_backup_20261125'
    into v_backup;
  end if;

  return pg_catalog.concat_ws(
    ',',
    (select count(*) from private.billing_credentials where billing_key is not null),
    v_backup,
    (select count(*) from public.gyms where billing_subscription_id is not null),
    (select count(*) from public.payment_attempts where billing_key_ref is not null),
    (select count(*) from private.billing_vault_cleared),
    (select count(*) from vault.secrets),
    (select count(*) from public.checkout_sessions),
    (select p.prosrc like '%billing_subscription_id%'
     from pg_proc p
     where p.oid = 'private.resolve_toss_billing_credential(uuid)'::regprocedure)
  );
end;
$state$;

select set_config('app.allow_billing_update', '1', true);

insert into public.gyms (id, name, billing_provider, billing_subscription_id)
select gym_a, 'Synthetic P132 A', 'toss', legacy_a from p1_32_context
union all
select gym_b, 'Synthetic P132 B', 'toss', key_b from p1_32_context
union all
select gym_c, 'Synthetic P132 C', 'toss', key_c from p1_32_context
union all
select gym_d, 'Synthetic P132 D', 'toss', null::text from p1_32_context
union all
select gym_e, 'Synthetic P132 E', 'toss', null::text from p1_32_context
union all
select gym_f, 'Synthetic P132 F', 'toss', null::text from p1_32_context;

alter table private.billing_credentials disable trigger billing_credentials_vault_key;
insert into private.billing_credentials (gym_id, provider, billing_key)
select gym_a, 'toss', key_a from p1_32_context;
alter table private.billing_credentials enable trigger billing_credentials_vault_key;

insert into private.billing_credentials_backup_20261125 (gym_id, provider, billing_key)
select gym_a, 'toss', key_a from p1_32_context;

-- Same path production took: original credential plus two gym fallbacks.
select private.copy_billing_keys_to_vault();

insert into public.payment_attempts (
  gym_id, provider, payment_type, amount_krw, order_id, billing_key_ref, status
)
select gym_a, 'toss', 'auto_renewal', 10000, 'synthetic-p132-order-a', legacy_a, 'initiated'
from p1_32_context
union all
select gym_b, 'toss', 'auto_renewal', 10000, 'synthetic-p132-order-b', key_b, 'initiated'
from p1_32_context
union all
select gym_c, 'toss', 'auto_renewal', 10000, 'synthetic-p132-order-c', key_c, 'initiated'
from p1_32_context;

insert into auth.users (id, email)
select gym_a, 'p132@example.test' from p1_32_context;

create temp table p1_32_baseline on commit drop as
select pg_temp.p1_32_state() as state;

insert into p1_32_results
select
  'fixture matches the expected production shape',
  case when (select state from p1_32_baseline) = '3,1,3,3,0,3,0,t'
    then 'PASS' else 'FAIL' end,
  (select state from p1_32_baseline);

-- ---- Pre-check failures: each aborts and leaves everything unchanged -------

create temp table p1_32_fail_cases (
  test_name text primary key,
  prefix_sql text not null,
  expected_error text not null
) on commit drop;

insert into p1_32_fail_cases
select
  'abort: a credential has no Vault secret',
  format(
    'delete from vault.secrets where id = (select vault_secret_id from private.billing_credentials where gym_id = %L);',
    gym_c
  ),
  'readable vault credentials=2 expected=3'
from p1_32_context
union all
select
  'abort: a Vault secret decrypts to an empty value',
  format(
    'select vault.update_secret((select vault_secret_id from private.billing_credentials where gym_id = %L), %L, null, null);',
    gym_b, ' '
  ),
  'readable vault credentials=2 expected=3'
from p1_32_context
union all
select
  'abort: one more attempt reference than expected',
  format(
    'insert into public.payment_attempts (gym_id, provider, payment_type, amount_krw, order_id, billing_key_ref, status) values (%L, %L, %L, 10000, %L, %L, %L);',
    gym_b, 'toss', 'auto_renewal', 'synthetic-p132-order-extra', key_b, 'initiated'
  ),
  'attempt refs=4 expected=3'
from p1_32_context
union all
select
  'abort: one more credential row than expected',
  format('select public.upsert_gym_billing_credential(%L, %L, %L);', gym_d, 'p132-fake-cred-d', 'toss'),
  'credential rows=4 expected=3'
from p1_32_context
union all
select
  'abort: plaintext differs from Vault',
  format(
    'alter table private.billing_credentials disable trigger billing_credentials_vault_key; update private.billing_credentials set billing_key = %L where gym_id = %L;',
    'synthetic-p132-other', gym_b
  ),
  'credential plaintext differs from vault rows=1'
from p1_32_context
union all
select
  'abort: backup copy is not in Vault',
  format(
    'update private.billing_credentials_backup_20261125 set billing_key = %L where gym_id = %L;',
    'synthetic-p132-other', gym_a
  ),
  'backup rows not in vault=1'
from p1_32_context
union all
select
  'abort: backup row count differs',
  'delete from private.billing_credentials_backup_20261125;',
  'backup rows=0 expected=1'
from p1_32_context
union all
select
  'abort: a toss gym fallback count differs',
  format('update public.gyms set billing_subscription_id = null where id = %L;', gym_c),
  'gym plaintext=2 expected=3'
from p1_32_context
union all
select
  'abort: checkout raw still holds a sensitive key',
  format(
    'alter table public.checkout_sessions disable trigger checkout_sessions_redact_payload; insert into public.checkout_sessions (gym_id, user_id, provider, interval, order_id, raw) values (%L, %L, %L, %L, %L, %L::jsonb);',
    gym_a, gym_a, 'toss', 'monthly', 'synthetic-p132-checkout', '{"paymentKey":"synthetic-p132-payment"}'
  ),
  'checkout raw to mask=1 expected=0'
from p1_32_context;

insert into p1_32_results
select
  f.test_name,
  case
    when r.err like 'BILLING_PLAINTEXT_PURGE_ABORTED%'
     and r.err like '%' || f.expected_error || '%'
     and pg_temp.p1_32_state() = (select state from p1_32_baseline)
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_32_state() || ' | ' || coalesce(r.err, 'null')
from p1_32_fail_cases f
cross join lateral (
  select pg_temp.p1_32_try(f.prefix_sql || E'\n' || current_setting('p1_32.purge_sql')) as err
) r;

-- ---- Pass case: the file exactly as committed -------------------------------

create temp table p1_32_run on commit drop as
select pg_temp.p1_32_try(current_setting('p1_32.purge_sql')) as result;

insert into p1_32_results
select 'purge runs on the expected shape', case when result = 'OK' then 'PASS' else 'FAIL' end, result
from p1_32_run;

insert into p1_32_results
select
  'after purge: 0 plaintext in credentials, backup, gyms, attempts',
  case
    when (select count(*) from private.billing_credentials where billing_key is not null) = 0
     and to_regclass('private.billing_credentials_backup_20261125') is null
     and (select count(*) from public.gyms where billing_provider = 'toss' and billing_subscription_id is not null) = 0
     and (select count(*) from public.payment_attempts where billing_key_ref is not null) = 0
    then 'PASS' else 'FAIL'
  end,
  pg_temp.p1_32_state();

insert into p1_32_results
select
  'after purge: charges still read every key from Vault',
  case
    when public.read_gym_billing_vault_credential(gym_a) = key_a
     and public.read_gym_billing_vault_credential(gym_b) = key_b
     and public.read_gym_billing_vault_credential(gym_c) = key_c
     and public.read_gym_billing_credential(gym_a) = key_a
     and private.resolve_toss_billing_credential(gym_b) = key_b
     and private.gym_has_billing_credential(gym_c)
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context;

insert into p1_32_results
select
  'after purge: every cleared value is kept in Vault, 1 new legacy secret',
  case
    when (select count(*) from private.billing_vault_cleared) = 6
     and (select count(*) from private.billing_vault_cleared cl
          where private.read_billing_vault_secret(cl.secret_id) is not null) = 6
     and (select count(*) from vault.secrets where name like 'billing_key_legacy:%') = 1
     and (select count(*) from vault.secrets) = 4
     and (select private.read_billing_vault_secret(cl.secret_id)
          from private.billing_vault_cleared cl
          where cl.target = 'gyms' and cl.row_id = ctx.gym_a) = ctx.legacy_a
     and (select private.read_billing_vault_secret(cl.secret_id)
          from private.billing_vault_cleared cl
          join public.payment_attempts pa on pa.id = cl.row_id
          where cl.target = 'payment_attempts' and pa.order_id = 'synthetic-p132-order-b') = ctx.key_b
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context ctx;

-- The renewal claim still finds a due gym and hands back its Vault key.
select set_config('app.allow_billing_update', '1', true);
update public.gyms g
set
  auto_renew = true,
  subscription_status = 'active',
  billing_customer_id = 'synthetic-p132-customer-b',
  current_period_end = timestamptz '2026-01-01 00:00:00+00'
from p1_32_context ctx
where g.id = ctx.gym_b;

create temp table p1_32_claim on commit drop as
select c.gym_id, c.billing_key_ref, c.payment_attempt_id
from public.claim_due_toss_subscription_charges(timestamptz '2026-01-02 00:00:00+00', 10, 10000) c;

insert into p1_32_results
select
  'after purge: renewal claim still gets the key from Vault',
  case
    when (select count(*) from p1_32_claim) = 1
     and cl.gym_id = ctx.gym_b
     and cl.billing_key_ref = ctx.key_b
     and pa.billing_key_ref is null
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context ctx
join p1_32_claim cl on true
join public.payment_attempts pa on pa.id = cl.payment_attempt_id;

-- Vault-only behaviour after purge.
select set_config('app.allow_billing_update', '1', true);
update public.gyms g
set billing_subscription_id = 'synthetic-p132-fallback-d'
from p1_32_context ctx
where g.id = ctx.gym_d;

insert into p1_32_results
select
  'after purge: a gym fallback value is no longer used',
  case
    when private.resolve_toss_billing_credential(gym_d) is null
     and not private.gym_has_billing_credential(gym_d)
     and public.read_gym_billing_credential(gym_d) is null
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context;

select public.upsert_gym_billing_credential(gym_e, 'p132-fake-cred-e', 'toss')
from p1_32_context;

insert into private.billing_credentials (gym_id, provider, billing_key)
select gym_f, 'toss', 'p132-fake-cred-f' from p1_32_context;

insert into p1_32_results
select
  'after purge: new keys go to Vault and billing_key stays NULL',
  case
    when e.billing_key is null
     and f.billing_key is null
     and public.read_gym_billing_vault_credential(ctx.gym_e) = 'p132-fake-cred-e'
     and public.read_gym_billing_vault_credential(ctx.gym_f) = 'p132-fake-cred-f'
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context ctx
join private.billing_credentials e on e.gym_id = ctx.gym_e
join private.billing_credentials f on f.gym_id = ctx.gym_f;

insert into p1_32_results
select
  'after purge: a second run aborts and changes nothing',
  case
    when r.err like 'BILLING_PLAINTEXT_PURGE_ABORTED%credential rows=5 expected=3%'
     and pg_temp.p1_32_state() = s.before
    then 'PASS' else 'FAIL'
  end,
  coalesce(r.err, 'null')
from (select pg_temp.p1_32_state() as before) s
cross join lateral (
  select pg_temp.p1_32_try(current_setting('p1_32.purge_sql')) as err
) r;

-- ---- Rollback: restore plaintext from Vault -------------------------------

select set_config('app.allow_billing_update', '1', true);
update public.gyms g
set billing_subscription_id = null
from p1_32_context ctx
where g.id = ctx.gym_d;

create temp table p1_32_restore on commit drop as
select pg_temp.p1_32_try(current_setting('p1_32.restore_sql')) as result;

insert into p1_32_results
select 'rollback runs', case when result = 'OK' then 'PASS' else 'FAIL' end, result
from p1_32_restore;

insert into p1_32_results
select
  'after rollback: original plaintext values are back',
  case
    when ca.billing_key = ctx.key_a
     and cb.billing_key = ctx.key_b
     and cc.billing_key = ctx.key_c
     and ga.billing_subscription_id = ctx.legacy_a
     and gb.billing_subscription_id = ctx.key_b
     and gc.billing_subscription_id = ctx.key_c
     and pa.billing_key_ref = ctx.legacy_a
     and pb.billing_key_ref = ctx.key_b
     and pc.billing_key_ref = ctx.key_c
     and (select count(*) from private.billing_vault_cleared) = 0
     and (select count(*) from vault.secrets where name like 'billing_key_legacy:%') = 0
     and public.read_gym_billing_vault_credential(ctx.gym_a) = ctx.key_a
    then 'PASS' else 'FAIL'
  end,
  'compared'
from p1_32_context ctx
join private.billing_credentials ca on ca.gym_id = ctx.gym_a
join private.billing_credentials cb on cb.gym_id = ctx.gym_b
join private.billing_credentials cc on cc.gym_id = ctx.gym_c
join public.gyms ga on ga.id = ctx.gym_a
join public.gyms gb on gb.id = ctx.gym_b
join public.gyms gc on gc.id = ctx.gym_c
join public.payment_attempts pa on pa.order_id = 'synthetic-p132-order-a'
join public.payment_attempts pb on pb.order_id = 'synthetic-p132-order-b'
join public.payment_attempts pc on pc.order_id = 'synthetic-p132-order-c';

insert into p1_32_results
select
  'after rollback: p1_31 code paths are back',
  case
    when (select p.prosrc like '%billing_subscription_id%'
          from pg_proc p
          where p.oid = 'private.resolve_toss_billing_credential(uuid)'::regprocedure)
     and (select p.prosrc not like '%new.billing_key := null%'
          from pg_proc p
          where p.oid = 'private.vault_billing_key()'::regprocedure)
    then 'PASS' else 'FAIL'
  end,
  'compared';

insert into p1_32_results
select
  'after rollback: p1_31 rollback still restores',
  case when pg_temp.p1_32_try('select private.rollback_billing_keys_from_vault();') = 'OK'
    then 'PASS' else 'FAIL' end,
  'called';

select test_name, status, detail
from p1_32_results
order by test_name;

rollback;
