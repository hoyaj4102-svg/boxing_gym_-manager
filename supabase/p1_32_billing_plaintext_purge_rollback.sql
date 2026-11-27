-- =============================================================================
-- Undo supabase/p1_32_billing_plaintext_purge_once.sql from Vault.
--
-- requires Founder approval before applying to production
--
-- Run in ONE transaction (apply_migration, or psql --single-transaction
-- -v ON_ERROR_STOP=1). The first statement is LOCK TABLE, so a plain
-- autocommit run stops before any change.
--
-- What it does:
--   1. Puts back the p1_31 versions of the Vault trigger, the credential
--      resolver, and the credential upsert, and the p0 version of
--      gym_has_billing_credential.
--   2. Checks that every credential and every row in
--      private.billing_vault_cleared still decrypts from Vault. If not, it
--      raises BILLING_PLAINTEXT_RESTORE_INCOMPLETE and changes nothing.
--   3. Writes the Vault values back into billing_credentials.billing_key,
--      gyms.billing_subscription_id, and payment_attempts.billing_key_ref
--      (only where the column is still NULL).
--   4. Deletes the legacy Vault secrets p1_32 created, and empties
--      private.billing_vault_cleared.
-- The p1_31 backup table that p1_32 dropped is not recreated. Its row equalled
-- the Vault value of the same credential, which step 3 restores.
-- Restored values are trimmed of surrounding spaces, as Vault stored them.
-- After this file, supabase/p1_31_billing_vault_rollback.sql still works.
-- This file stores no identifier or key and prints counts only.
-- =============================================================================

lock table
  private.billing_credentials,
  public.gyms,
  public.payment_attempts,
  private.billing_vault_cleared
in share row exclusive mode;

create or replace function private.vault_billing_key()
returns trigger
language plpgsql
security definer
set search_path = ''
as $vault_trigger$
declare
  v_key text := pg_catalog.btrim(new.billing_key);
begin
  if v_key is null or pg_catalog.length(v_key) = 0 then
    return new;
  end if;

  new.vault_secret_id := private.sync_billing_vault_secret(
    new.gym_id,
    new.provider,
    v_key,
    true
  );
  perform private.remember_billing_vault_origin(
    new.gym_id,
    new.provider,
    new.vault_secret_id,
    'billing_credentials'
  );
  return new;
end;
$vault_trigger$;

revoke all on function private.vault_billing_key() from public;
revoke all on function private.vault_billing_key() from anon, authenticated;
grant execute on function private.vault_billing_key() to service_role;

create or replace function private.resolve_toss_billing_credential(p_gym_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $resolve_credential$
declare
  v_key text;
begin
  select private.read_billing_vault_secret(c.vault_secret_id)
  into v_key
  from private.billing_credentials c
  where c.gym_id = p_gym_id
    and c.provider = 'toss'
  limit 1;

  if v_key is not null then
    return v_key;
  end if;

  select pg_catalog.btrim(c.billing_key)
  into v_key
  from private.billing_credentials c
  where c.gym_id = p_gym_id
    and c.provider = 'toss'
    and c.billing_key is not null
    and pg_catalog.length(pg_catalog.btrim(c.billing_key)) > 0
  limit 1;

  if v_key is not null then
    return v_key;
  end if;

  select pg_catalog.btrim(g.billing_subscription_id)
  into v_key
  from public.gyms g
  where g.id = p_gym_id
    and g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and pg_catalog.length(pg_catalog.btrim(g.billing_subscription_id)) > 0;

  return v_key;
end;
$resolve_credential$;

revoke all on function private.resolve_toss_billing_credential(uuid) from public;
revoke all on function private.resolve_toss_billing_credential(uuid) from anon, authenticated;

create or replace function private.gym_has_billing_credential(p_gym_id uuid)
returns boolean
language sql
stable
security definer
set search_path = private, public
as $$
  select private.resolve_toss_billing_credential(p_gym_id) is not null
    or exists (
      select 1
      from public.gyms g
      where g.id = p_gym_id
        and g.billing_subscription_id is not null
        and length(btrim(g.billing_subscription_id)) > 0
    );
$$;

revoke all on function private.gym_has_billing_credential(uuid) from public;
revoke all on function private.gym_has_billing_credential(uuid) from anon, authenticated;

create or replace function public.upsert_gym_billing_credential(
  p_gym_id uuid,
  p_billing_key text,
  p_provider text default 'toss'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $upsert_credential$
declare
  v_id uuid;
  v_provider text := coalesce(nullif(pg_catalog.btrim(p_provider), ''), 'toss');
  v_key text := pg_catalog.btrim(p_billing_key);
  v_secret_id uuid;
begin
  if p_gym_id is null then
    raise exception 'GYM_ID_REQUIRED';
  end if;

  if v_provider not in ('toss', 'stripe') then
    raise exception 'BILLING_PROVIDER_UNSUPPORTED';
  end if;

  if v_key is null or pg_catalog.length(v_key) = 0 then
    raise exception 'BILLING_CREDENTIAL_REQUIRED';
  end if;

  v_secret_id := private.sync_billing_vault_secret(p_gym_id, v_provider, v_key, true);
  perform private.remember_billing_vault_origin(
    p_gym_id,
    v_provider,
    v_secret_id,
    'billing_credentials'
  );

  insert into private.billing_credentials (
    gym_id,
    provider,
    billing_key,
    vault_secret_id
  )
  values (
    p_gym_id,
    v_provider,
    v_key,
    v_secret_id
  )
  on conflict (gym_id, provider) do update
  set
    billing_key = excluded.billing_key,
    vault_secret_id = excluded.vault_secret_id,
    updated_at = pg_catalog.now()
  returning id into v_id;

  return v_id;
end;
$upsert_credential$;

revoke all on function public.upsert_gym_billing_credential(uuid, text, text) from public;
revoke all on function public.upsert_gym_billing_credential(uuid, text, text) from anon, authenticated;
grant execute on function public.upsert_gym_billing_credential(uuid, text, text) to service_role;

comment on column private.billing_credentials.billing_key is
  'Legacy plaintext. A later approved step clears it after Vault rollback can restore it.';

do $restore$
declare
  v_count integer;
  v_credentials integer := 0;
  v_gyms integer := 0;
  v_attempts integer := 0;
  v_legacy integer := 0;
begin
  select count(*) into v_count
  from private.billing_credentials c
  where private.read_billing_vault_secret(c.vault_secret_id) is null;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_RESTORE_INCOMPLETE credentials without vault=%', v_count;
  end if;

  select count(*) into v_count
  from private.billing_vault_cleared cl
  where private.read_billing_vault_secret(cl.secret_id) is null;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_RESTORE_INCOMPLETE cleared rows without vault=%', v_count;
  end if;

  alter table private.billing_credentials disable trigger billing_credentials_vault_key;
  perform pg_catalog.set_config('app.allow_billing_update', '1', true);

  update private.billing_credentials c
  set billing_key = private.read_billing_vault_secret(c.vault_secret_id)
  where c.billing_key is null;
  get diagnostics v_credentials = row_count;

  alter table private.billing_credentials enable trigger billing_credentials_vault_key;

  update public.gyms g
  set billing_subscription_id = private.read_billing_vault_secret(cl.secret_id)
  from private.billing_vault_cleared cl
  where cl.target = 'gyms'
    and cl.row_id = g.id
    and g.billing_subscription_id is null;
  get diagnostics v_gyms = row_count;

  update public.payment_attempts pa
  set billing_key_ref = private.read_billing_vault_secret(cl.secret_id)
  from private.billing_vault_cleared cl
  where cl.target = 'payment_attempts'
    and cl.row_id = pa.id
    and pa.billing_key_ref is null;
  get diagnostics v_attempts = row_count;

  delete from vault.secrets s
  where s.name like 'billing_key_legacy:%'
    and s.id in (select cl.secret_id from private.billing_vault_cleared cl)
    and not exists (
      select 1 from private.billing_credentials c where c.vault_secret_id = s.id
    )
    and not exists (
      select 1 from private.billing_vault_origins o where o.secret_id = s.id
    );
  get diagnostics v_legacy = row_count;

  delete from private.billing_vault_cleared;

  select count(*) into v_count
  from private.billing_credentials c
  where c.billing_key is null
     or pg_catalog.btrim(c.billing_key)
        is distinct from private.read_billing_vault_secret(c.vault_secret_id);
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_RESTORE_INCOMPLETE credential mismatch=%', v_count;
  end if;

  raise notice
    'p1_32 restore done credentials=% gyms=% attempts=% legacy_secrets_deleted=%',
    v_credentials, v_gyms, v_attempts, v_legacy;
end
$restore$;
