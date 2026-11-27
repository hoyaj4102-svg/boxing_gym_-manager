-- =============================================================================
-- p1_32 Remove plaintext billing keys now that charges read them from Vault.
--
-- requires Founder approval before applying to production
--
-- One-time data change. Apply after p1_31_billing_vault, in ONE transaction:
--   * Supabase apply_migration (runs the file in one transaction), or
--   * psql --single-transaction -v ON_ERROR_STOP=1 -f <this file>
-- The first statement is LOCK TABLE. Postgres refuses LOCK TABLE outside a
-- transaction block, so a plain autocommit run stops before any change.
-- scripts/run-sql-tests.sh skips *_once.sql when it builds the CI schema.
-- supabase/p1_32_billing_plaintext_purge_test.sql runs this exact file on
-- synthetic rows.
--
-- What it does, in order:
--   1. Locks the billing tables.
--   2. Makes the database Vault-only:
--      - the billing_credentials trigger moves a written key into Vault and
--        stores NULL in billing_key,
--      - upsert_gym_billing_credential writes the key to Vault only,
--      - resolve_toss_billing_credential and gym_has_billing_credential no
--        longer fall back to billing_key or gyms.billing_subscription_id.
--   3. Pre-check. Aborts (RAISE EXCEPTION, whole transaction rolls back) unless
--      every count below matches exactly, every credential row has a Vault
--      secret that decrypts to a non-empty value equal to its plaintext, and
--      the backup copy equals the Vault value of the same credential.
--   4. Every plaintext value that is about to be cleared from gyms or
--      payment_attempts is kept in Vault first. If it already equals that
--      gym's Vault credential, that secret is reused. Otherwise one new Vault
--      secret is created and read back. Each cleared row is recorded in
--      private.billing_vault_cleared (target, row id, secret id). That is the
--      table the p1_31 rollback already restores from.
--   5. Clears: billing_credentials.billing_key, the p1_31 backup table
--      (dropped), gyms.billing_subscription_id for toss gyms,
--      payment_attempts.billing_key_ref, and masks sensitive keys left in
--      checkout_sessions.raw.
--   6. Post-check. Aborts unless 0 plaintext remains in each place and every
--      credential and every cleared row still decrypts from Vault.
--
-- Counts below come from a read-only count on 2026-11-27 KST. Re-count right
-- before apply. If any count differs, stop and ask again; do not edit the
-- numbers to make the file pass without a new approval.
-- No identifier, key, or personal value is stored in this file. Notices
-- print counts only.
--
-- Undo: supabase/p1_32_billing_plaintext_purge_rollback.sql restores the
-- plaintext columns from Vault. The dropped backup table is not recreated.
-- Its one row equalled the Vault value of the same credential (pre-check).
--
-- This file does not enable the charge scheduler, does not call a provider,
-- and does not change grants.
-- =============================================================================

lock table
  private.billing_credentials,
  public.gyms,
  public.payment_attempts,
  public.checkout_sessions,
  private.billing_vault_cleared
in share row exclusive mode;

-- -----------------------------------------------------------------------------
-- 2. Vault-only code paths.
-- -----------------------------------------------------------------------------

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
    new.billing_key := null;
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
  -- p1_32: the key lives in Vault only.
  new.billing_key := null;
  return new;
end;
$vault_trigger$;

revoke all on function private.vault_billing_key() from public;
revoke all on function private.vault_billing_key() from anon, authenticated;
grant execute on function private.vault_billing_key() to service_role;

create or replace function private.resolve_toss_billing_credential(p_gym_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $resolve_credential$
  select private.read_billing_vault_secret(c.vault_secret_id)
  from private.billing_credentials c
  where c.gym_id = p_gym_id
    and c.provider = 'toss'
  limit 1;
$resolve_credential$;

revoke all on function private.resolve_toss_billing_credential(uuid) from public;
revoke all on function private.resolve_toss_billing_credential(uuid) from anon, authenticated;

create or replace function private.gym_has_billing_credential(p_gym_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $has_credential$
  select private.resolve_toss_billing_credential(p_gym_id) is not null;
$has_credential$;

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
    null,
    v_secret_id
  )
  on conflict (gym_id, provider) do update
  set
    billing_key = null,
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
  'Legacy plaintext. Cleared by p1_32 and kept NULL by the Vault trigger.';

-- -----------------------------------------------------------------------------
-- 3-6. Pre-check, keep in Vault, clear, post-check. One statement.
-- -----------------------------------------------------------------------------

do $purge$
declare
  -- Expected counts (read-only count, 2026-11-27 KST). Re-count before apply.
  c_credential_rows       constant integer := 3; -- credential rows, all with Vault
  c_credential_plaintext  constant integer := 3; -- of those, billing_key not empty
  c_backup_rows           constant integer := 1; -- p1_31 backup copy rows
  c_gym_plaintext         constant integer := 3; -- toss gyms with billing_subscription_id
  c_attempt_refs          constant integer := 3; -- payment_attempts with billing_key_ref
  c_new_legacy_secrets    constant integer := 1; -- cleared values not equal to a Vault credential
  c_checkout_redactions   constant integer := 0; -- checkout_sessions.raw rows still to mask

  v_count integer;
  v_backup_exists boolean := to_regclass('private.billing_credentials_backup_20261125') is not null;
  v_rec record;
  v_value text;
  v_secret_id uuid;
  v_new_legacy integer := 0;
  v_cleared_gyms integer := 0;
  v_cleared_attempts integer := 0;
  v_cleared_credentials integer := 0;
  v_masked_checkout integer := 0;
begin
  -- Required objects.
  if to_regprocedure('private.read_billing_vault_secret(uuid)') is null
     or to_regclass('private.billing_vault_cleared') is null
     or to_regclass('private.billing_vault_origins') is null then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED p1_31 objects are missing';
  end if;

  -- Hosted Vault has create_secret(text,text,text,uuid); the CI stand-in has
  -- the 3-argument form. Both accept the 3-argument call below.
  if to_regprocedure('vault.create_secret(text,text,text)') is null
     and to_regprocedure('vault.create_secret(text,text,text,uuid)') is null then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED vault.create_secret is missing';
  end if;

  if to_regprocedure('private.mask_sensitive_stored_payload(jsonb)') is null then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED mask_sensitive_stored_payload is missing';
  end if;

  if v_backup_exists then
    execute 'lock table private.billing_credentials_backup_20261125 in share row exclusive mode';
  end if;

  -- ---- 3. Pre-check ---------------------------------------------------------

  select count(*) into v_count from private.billing_credentials;
  if v_count <> c_credential_rows then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED credential rows=% expected=%',
      v_count, c_credential_rows;
  end if;

  select count(*) into v_count
  from private.billing_credentials c
  where c.vault_secret_id is not null
    and private.read_billing_vault_secret(c.vault_secret_id) is not null;
  if v_count <> c_credential_rows then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED readable vault credentials=% expected=%',
      v_count, c_credential_rows;
  end if;

  select count(*) into v_count
  from private.billing_credentials c
  where c.billing_key is not null
    and pg_catalog.length(pg_catalog.btrim(c.billing_key)) > 0;
  if v_count <> c_credential_plaintext then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED credential plaintext=% expected=%',
      v_count, c_credential_plaintext;
  end if;

  select count(*) into v_count
  from private.billing_credentials c
  where c.billing_key is not null
    and pg_catalog.length(pg_catalog.btrim(c.billing_key)) > 0
    and private.read_billing_vault_secret(c.vault_secret_id)
      is distinct from pg_catalog.btrim(c.billing_key);
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED credential plaintext differs from vault rows=%',
      v_count;
  end if;

  if v_backup_exists then
    execute 'select count(*) from private.billing_credentials_backup_20261125'
    into v_count;
  else
    v_count := 0;
  end if;
  if v_count <> c_backup_rows then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED backup rows=% expected=%',
      v_count, c_backup_rows;
  end if;

  if v_backup_exists then
    execute $q$
      select count(*)
      from private.billing_credentials_backup_20261125 b
      where b.billing_key is not null
        and pg_catalog.length(pg_catalog.btrim(b.billing_key)) > 0
        and not exists (
          select 1
          from private.billing_credentials c
          where c.gym_id = b.gym_id
            and c.provider = b.provider
            and private.read_billing_vault_secret(c.vault_secret_id)
              = pg_catalog.btrim(b.billing_key)
        )
    $q$
    into v_count;
    if v_count <> 0 then
      raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED backup rows not in vault=%', v_count;
    end if;
  end if;

  select count(*) into v_count
  from public.gyms g
  where g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and pg_catalog.length(pg_catalog.btrim(g.billing_subscription_id)) > 0;
  if v_count <> c_gym_plaintext then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED gym plaintext=% expected=%',
      v_count, c_gym_plaintext;
  end if;

  select count(*) into v_count
  from public.payment_attempts pa
  where pa.billing_key_ref is not null
    and pg_catalog.length(pg_catalog.btrim(pa.billing_key_ref)) > 0;
  if v_count <> c_attempt_refs then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED attempt refs=% expected=%',
      v_count, c_attempt_refs;
  end if;

  select count(*) into v_count from private.billing_vault_cleared;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED billing_vault_cleared is not empty rows=%',
      v_count;
  end if;

  select count(*) into v_count
  from public.checkout_sessions cs
  where cs.raw is distinct from private.mask_sensitive_stored_payload(cs.raw);
  if v_count <> c_checkout_redactions then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED checkout raw to mask=% expected=%',
      v_count, c_checkout_redactions;
  end if;

  -- ---- 4. Keep every value that will be cleared in Vault ----------------------

  for v_rec in
    select 'gyms'::text as target, g.id as row_id, g.id as gym_id,
           pg_catalog.btrim(g.billing_subscription_id) as secret_value
    from public.gyms g
    where g.billing_provider = 'toss'
      and g.billing_subscription_id is not null
      and pg_catalog.length(pg_catalog.btrim(g.billing_subscription_id)) > 0
    union all
    select 'payment_attempts'::text, pa.id, pa.gym_id,
           pg_catalog.btrim(pa.billing_key_ref)
    from public.payment_attempts pa
    where pa.billing_key_ref is not null
      and pg_catalog.length(pg_catalog.btrim(pa.billing_key_ref)) > 0
    order by 1, 2
  loop
    v_secret_id := null;

    -- Same value as this gym's Vault credential: reuse that secret.
    select c.vault_secret_id into v_secret_id
    from private.billing_credentials c
    where c.gym_id = v_rec.gym_id
      and c.vault_secret_id is not null
      and private.read_billing_vault_secret(c.vault_secret_id) = v_rec.secret_value
    limit 1;

    -- Same value already kept for this gym earlier in this loop: reuse it.
    if v_secret_id is null then
      select cl.secret_id into v_secret_id
      from private.billing_vault_cleared cl
      left join public.gyms g
        on cl.target = 'gyms' and g.id = cl.row_id
      left join public.payment_attempts pa
        on cl.target = 'payment_attempts' and pa.id = cl.row_id
      where coalesce(g.id, pa.gym_id) = v_rec.gym_id
        and private.read_billing_vault_secret(cl.secret_id) = v_rec.secret_value
      limit 1;
    end if;

    if v_secret_id is null then
      v_secret_id := vault.create_secret(
        v_rec.secret_value,
        'billing_key_legacy:' || v_rec.target || ':' || v_rec.row_id::text,
        'legacy billing value cleared by p1_32'
      );
      v_new_legacy := v_new_legacy + 1;
    end if;

    if private.read_billing_vault_secret(v_secret_id) is distinct from v_rec.secret_value then
      raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED vault read-back mismatch target=%',
        v_rec.target;
    end if;

    insert into private.billing_vault_cleared (target, row_id, secret_id)
    values (v_rec.target, v_rec.row_id, v_secret_id);
  end loop;

  if v_new_legacy <> c_new_legacy_secrets then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED new legacy secrets=% expected=%',
      v_new_legacy, c_new_legacy_secrets;
  end if;

  -- ---- 5. Clear -----------------------------------------------------------------

  perform pg_catalog.set_config('app.allow_billing_update', '1', true);

  update private.billing_credentials c
  set billing_key = null
  where c.billing_key is not null;
  get diagnostics v_cleared_credentials = row_count;

  if v_backup_exists then
    execute 'drop table private.billing_credentials_backup_20261125';
  end if;

  update public.gyms g
  set billing_subscription_id = null
  from private.billing_vault_cleared cl
  where cl.target = 'gyms'
    and cl.row_id = g.id
    and g.billing_subscription_id is not null;
  get diagnostics v_cleared_gyms = row_count;

  update public.payment_attempts pa
  set billing_key_ref = null
  from private.billing_vault_cleared cl
  where cl.target = 'payment_attempts'
    and cl.row_id = pa.id
    and pa.billing_key_ref is not null;
  get diagnostics v_cleared_attempts = row_count;

  update public.checkout_sessions cs
  set raw = private.mask_sensitive_stored_payload(cs.raw)
  where cs.raw is distinct from private.mask_sensitive_stored_payload(cs.raw);
  get diagnostics v_masked_checkout = row_count;

  if v_cleared_gyms <> c_gym_plaintext
     or v_cleared_attempts <> c_attempt_refs
     or v_masked_checkout <> c_checkout_redactions then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED cleared gyms=% attempts=% checkout=%',
      v_cleared_gyms, v_cleared_attempts, v_masked_checkout;
  end if;

  -- ---- 6. Post-check --------------------------------------------------------------

  select count(*) into v_count
  from private.billing_credentials c
  where c.billing_key is not null;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED credential plaintext left=%', v_count;
  end if;

  if to_regclass('private.billing_credentials_backup_20261125') is not null then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED backup table still exists';
  end if;

  select count(*) into v_count
  from public.gyms g
  where g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and pg_catalog.length(pg_catalog.btrim(g.billing_subscription_id)) > 0;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED gym plaintext left=%', v_count;
  end if;

  select count(*) into v_count
  from public.payment_attempts pa
  where pa.billing_key_ref is not null
    and pg_catalog.length(pg_catalog.btrim(pa.billing_key_ref)) > 0;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED attempt refs left=%', v_count;
  end if;

  select count(*) into v_count
  from public.checkout_sessions cs
  where private.count_unredacted_sensitive_keys(cs.raw) > 0;
  if v_count <> 0 then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED checkout raw sensitive left=%', v_count;
  end if;

  select count(*) into v_count
  from private.billing_credentials c
  where private.read_billing_vault_secret(c.vault_secret_id) is not null;
  if v_count <> c_credential_rows then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED readable vault credentials after=% expected=%',
      v_count, c_credential_rows;
  end if;

  select count(*) into v_count
  from private.billing_vault_cleared cl
  where private.read_billing_vault_secret(cl.secret_id) is not null;
  if v_count <> c_gym_plaintext + c_attempt_refs then
    raise exception 'BILLING_PLAINTEXT_PURGE_ABORTED readable cleared rows=% expected=%',
      v_count, c_gym_plaintext + c_attempt_refs;
  end if;

  raise notice
    'p1_32 billing plaintext purge done credentials=% backup_rows=% gyms=% attempts=% checkout=% new_legacy_secrets=%',
    v_cleared_credentials, c_backup_rows, v_cleared_gyms, v_cleared_attempts,
    v_masked_checkout, v_new_legacy;
end
$purge$;
