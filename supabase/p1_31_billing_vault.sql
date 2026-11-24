-- =============================================================================
-- p1_31 Move Toss billing keys into Vault.
--
-- requires Founder approval before applying to production
--
-- Number: p1_31. Main stops at p1_28. Open drafts already use p1_20, p1_21,
-- p1_23, p1_24, p1_25, p1_29, and p1_30. Do not apply draft #76 (p1_23
-- through p1_25) in the same database as this file.
--
-- The copy and the decrypt check run in one function call. A mismatch raises
-- BILLING_VAULT_COPY_MISMATCH and rolls that call back. The plaintext column
-- is not cleared here. The existing payment-data rollback still copies
-- billing_key back into gyms, and re-applying that older SQL only knows how
-- to read the column. Clearing the column is a later step, after that
-- rollback is changed to restore from Vault. The column is nullable so that
-- later step can clear it. The column is not dropped.
--
-- This file does not enable the charge scheduler and does not call a provider.
-- =============================================================================

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
grant usage on schema private to service_role;

do $require_vault$
begin
  begin
    create extension if not exists supabase_vault;
  exception
    when others then
      if current_database() = 'ci_sql_tests'
         and (
           to_regprocedure('vault.create_secret(text,text,text)') is not null
           or to_regprocedure('vault.create_secret(text,text,text,uuid)') is not null
         ) then
        null;
      else
        raise exception 'supabase_vault extension is required';
      end if;
  end;

  if to_regprocedure('vault.create_secret(text,text,text)') is null
     and to_regprocedure('vault.create_secret(text,text,text,uuid)') is null then
    raise exception 'supabase_vault extension is required';
  end if;
end
$require_vault$;

do $vault_access$
declare
  v_proc regprocedure;
begin
  begin
    execute 'alter view vault.decrypted_secrets set (security_invoker = true)';
  exception
    when others then
      null;
  end;

  revoke all on schema vault from public, anon, authenticated, service_role;
  revoke all on all tables in schema vault from public, anon, authenticated, service_role;

  for v_proc in
    select p.oid::regprocedure
    from pg_catalog.pg_proc p
    join pg_catalog.pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'vault'
  loop
    execute format(
      'revoke all on function %s from public, anon, authenticated, service_role',
      v_proc
    );
  end loop;
end
$vault_access$;

alter table private.billing_credentials
  alter column billing_key drop not null;

alter table private.billing_credentials
  add column if not exists vault_secret_id uuid;

create unique index if not exists billing_credentials_vault_secret_id_idx
  on private.billing_credentials (vault_secret_id)
  where vault_secret_id is not null;

comment on column private.billing_credentials.billing_key is
  'Legacy plaintext. A later approved step clears it after Vault rollback can restore it.';

comment on column private.billing_credentials.vault_secret_id is
  'Vault secret id for the billing key. The key itself is not stored in this column.';

revoke all on table private.billing_credentials from public;
revoke all on table private.billing_credentials from anon, authenticated;
grant select, insert, update, delete on table private.billing_credentials to service_role;

create table if not exists private.billing_vault_origins (
  gym_id uuid not null,
  provider text not null check (provider in ('toss', 'stripe')),
  secret_id uuid not null unique,
  source text not null check (source in ('billing_credentials', 'gyms_fallback')),
  primary key (gym_id, provider)
);

create table if not exists private.billing_vault_cleared (
  target text not null check (target in ('gyms', 'payment_attempts')),
  row_id uuid not null,
  secret_id uuid not null,
  primary key (target, row_id)
);

alter table private.billing_vault_origins enable row level security;
alter table private.billing_vault_cleared enable row level security;

revoke all on table private.billing_vault_origins from public, anon, authenticated, service_role;
revoke all on table private.billing_vault_cleared from public, anon, authenticated, service_role;

comment on table private.billing_vault_origins is
  'Which Vault secret id replaced a billing key. The key is not stored here.';

comment on table private.billing_vault_cleared is
  'Reserved for the later step that clears plaintext. This migration does not write it.';

create or replace function private.read_billing_vault_secret(p_secret_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $read_secret$
declare
  v_secret text;
begin
  if p_secret_id is null then
    return null;
  end if;

  select pg_catalog.btrim(ds.decrypted_secret)
  into v_secret
  from vault.decrypted_secrets ds
  where ds.id = p_secret_id;

  if v_secret is null or pg_catalog.length(v_secret) = 0 then
    return null;
  end if;

  return v_secret;
end;
$read_secret$;

revoke all on function private.read_billing_vault_secret(uuid) from public;
revoke all on function private.read_billing_vault_secret(uuid) from anon, authenticated;
grant execute on function private.read_billing_vault_secret(uuid) to service_role;

create or replace function private.sync_billing_vault_secret(
  p_gym_id uuid,
  p_provider text,
  p_secret text,
  p_allow_rotate boolean
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $sync_secret$
declare
  v_provider text := pg_catalog.btrim(p_provider);
  v_secret text := pg_catalog.btrim(p_secret);
  v_name text;
  v_id uuid;
  v_current text;
begin
  if p_gym_id is null then
    raise exception 'GYM_ID_REQUIRED';
  end if;

  if v_provider not in ('toss', 'stripe') then
    raise exception 'BILLING_PROVIDER_UNSUPPORTED';
  end if;

  if v_secret is null or pg_catalog.length(v_secret) = 0 then
    raise exception 'BILLING_CREDENTIAL_REQUIRED';
  end if;

  v_name := 'billing_key:' || p_gym_id::text || ':' || v_provider;

  select ds.id
  into v_id
  from vault.decrypted_secrets ds
  where ds.name = v_name
  limit 1;

  if v_id is null then
    v_id := vault.create_secret(v_secret, v_name, 'billing credential');
  else
    v_current := private.read_billing_vault_secret(v_id);
    if v_current is distinct from v_secret then
      if not p_allow_rotate then
        raise exception 'BILLING_VAULT_COPY_MISMATCH';
      end if;
      perform vault.update_secret(v_id, v_secret, v_name, 'billing credential');
    end if;
  end if;

  if private.read_billing_vault_secret(v_id) is distinct from v_secret then
    raise exception 'BILLING_VAULT_COPY_MISMATCH';
  end if;

  return v_id;
end;
$sync_secret$;

revoke all on function private.sync_billing_vault_secret(uuid, text, text, boolean) from public;
revoke all on function private.sync_billing_vault_secret(uuid, text, text, boolean) from anon, authenticated;
revoke all on function private.sync_billing_vault_secret(uuid, text, text, boolean) from service_role;

create or replace function private.remember_billing_vault_origin(
  p_gym_id uuid,
  p_provider text,
  p_secret_id uuid,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = ''
as $remember_origin$
declare
  v_existing uuid;
begin
  insert into private.billing_vault_origins (gym_id, provider, secret_id, source)
  values (p_gym_id, p_provider, p_secret_id, p_source)
  on conflict (gym_id, provider) do nothing;

  select o.secret_id
  into v_existing
  from private.billing_vault_origins o
  where o.gym_id = p_gym_id
    and o.provider = p_provider;

  if v_existing is distinct from p_secret_id then
    raise exception 'BILLING_VAULT_COPY_MISMATCH';
  end if;
end;
$remember_origin$;

revoke all on function private.remember_billing_vault_origin(uuid, text, uuid, text) from public;
revoke all on function private.remember_billing_vault_origin(uuid, text, uuid, text) from anon, authenticated;
revoke all on function private.remember_billing_vault_origin(uuid, text, uuid, text) from service_role;

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

drop trigger if exists billing_credentials_vault_key on private.billing_credentials;
create trigger billing_credentials_vault_key
before insert or update of billing_key on private.billing_credentials
for each row
execute function private.vault_billing_key();

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

create or replace function public.read_gym_billing_vault_credential(p_gym_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $read_vault_credential$
  select private.read_billing_vault_secret(c.vault_secret_id)
  from private.billing_credentials c
  where c.gym_id = p_gym_id
    and c.provider = 'toss'
  limit 1;
$read_vault_credential$;

revoke all on function public.read_gym_billing_vault_credential(uuid) from public;
revoke all on function public.read_gym_billing_vault_credential(uuid) from anon, authenticated;
grant execute on function public.read_gym_billing_vault_credential(uuid) to service_role;

create or replace function public.read_gym_billing_credential(p_gym_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $read_credential$
  select private.resolve_toss_billing_credential(p_gym_id);
$read_credential$;

revoke all on function public.read_gym_billing_credential(uuid) from public;
revoke all on function public.read_gym_billing_credential(uuid) from anon, authenticated;
grant execute on function public.read_gym_billing_credential(uuid) to service_role;

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

create or replace function private.copy_billing_keys_to_vault()
returns void
language plpgsql
security definer
set search_path = ''
as $copy_keys$
declare
  v_rec record;
  v_secret_id uuid;
begin
  alter table private.billing_credentials disable trigger billing_credentials_vault_key;
  perform pg_catalog.set_config('app.allow_billing_update', '1', true);

  begin
    for v_rec in
      select
        c.gym_id,
        c.provider,
        pg_catalog.btrim(c.billing_key) as secret_value
      from private.billing_credentials c
      where c.billing_key is not null
        and pg_catalog.length(pg_catalog.btrim(c.billing_key)) > 0
    loop
      v_secret_id := private.sync_billing_vault_secret(
        v_rec.gym_id,
        v_rec.provider,
        v_rec.secret_value,
        false
      );

      if private.read_billing_vault_secret(v_secret_id) is distinct from v_rec.secret_value then
        raise exception 'BILLING_VAULT_COPY_MISMATCH';
      end if;

      perform private.remember_billing_vault_origin(
        v_rec.gym_id,
        v_rec.provider,
        v_secret_id,
        'billing_credentials'
      );

      update private.billing_credentials c
      set vault_secret_id = v_secret_id
      where c.gym_id = v_rec.gym_id
        and c.provider = v_rec.provider
        and private.read_billing_vault_secret(v_secret_id) = v_rec.secret_value;
    end loop;

    if exists (
      select 1
      from private.billing_credentials c
      where c.billing_key is not null
        and pg_catalog.length(pg_catalog.btrim(c.billing_key)) > 0
        and (
          c.vault_secret_id is null
          or private.read_billing_vault_secret(c.vault_secret_id)
            is distinct from pg_catalog.btrim(c.billing_key)
        )
    ) then
      raise exception 'BILLING_VAULT_COPY_MISMATCH';
    end if;

    for v_rec in
      select
        g.id as gym_id,
        pg_catalog.btrim(g.billing_subscription_id) as secret_value
      from public.gyms g
      where g.billing_provider = 'toss'
        and g.billing_subscription_id is not null
        and pg_catalog.length(pg_catalog.btrim(g.billing_subscription_id)) > 0
        and not exists (
          select 1
          from private.billing_credentials c
          where c.gym_id = g.id
            and c.provider = 'toss'
        )
    loop
      v_secret_id := private.sync_billing_vault_secret(
        v_rec.gym_id,
        'toss',
        v_rec.secret_value,
        false
      );

      if private.read_billing_vault_secret(v_secret_id) is distinct from v_rec.secret_value then
        raise exception 'BILLING_VAULT_COPY_MISMATCH';
      end if;

      insert into private.billing_credentials (
        gym_id,
        provider,
        billing_key,
        vault_secret_id
      )
      values (v_rec.gym_id, 'toss', v_rec.secret_value, v_secret_id);

      perform private.remember_billing_vault_origin(
        v_rec.gym_id,
        'toss',
        v_secret_id,
        'gyms_fallback'
      );
    end loop;

    alter table private.billing_credentials enable trigger billing_credentials_vault_key;
  exception
    when others then
      alter table private.billing_credentials enable trigger billing_credentials_vault_key;
      raise;
  end;
end;
$copy_keys$;

revoke all on function private.copy_billing_keys_to_vault() from public;
revoke all on function private.copy_billing_keys_to_vault() from anon, authenticated;
revoke all on function private.copy_billing_keys_to_vault() from service_role;

create or replace function private.rollback_billing_keys_from_vault()
returns void
language plpgsql
security definer
set search_path = ''
as $rollback_keys$
declare
  v_origin record;
  v_cleared record;
  v_secret text;
  v_current text;
begin
  alter table private.billing_credentials disable trigger billing_credentials_vault_key;
  perform pg_catalog.set_config('app.allow_billing_update', '1', true);

  begin
    for v_origin in
      select gym_id, provider, secret_id, source
      from private.billing_vault_origins
    loop
      v_secret := private.read_billing_vault_secret(v_origin.secret_id);
      if v_secret is null then
        raise exception 'BILLING_VAULT_ROLLBACK_INCOMPLETE';
      end if;
    end loop;

    for v_cleared in
      select target, row_id, secret_id
      from private.billing_vault_cleared
    loop
      v_secret := private.read_billing_vault_secret(v_cleared.secret_id);
      if v_secret is null then
        raise exception 'BILLING_VAULT_ROLLBACK_INCOMPLETE';
      end if;

      if v_cleared.target = 'gyms' then
        select pg_catalog.btrim(g.billing_subscription_id)
        into v_current
        from public.gyms g
        where g.id = v_cleared.row_id;

        if v_current is not null and v_current is distinct from v_secret then
          raise exception 'BILLING_VAULT_ROLLBACK_UNSAFE';
        end if;
      else
        select pg_catalog.btrim(pa.billing_key_ref)
        into v_current
        from public.payment_attempts pa
        where pa.id = v_cleared.row_id;

        if v_current is not null and v_current is distinct from v_secret then
          raise exception 'BILLING_VAULT_ROLLBACK_UNSAFE';
        end if;
      end if;
    end loop;

    for v_origin in
      select gym_id, provider, secret_id, source
      from private.billing_vault_origins
    loop
      v_secret := private.read_billing_vault_secret(v_origin.secret_id);

      if v_origin.source = 'billing_credentials' then
        update private.billing_credentials c
        set
          billing_key = v_secret,
          vault_secret_id = null
        where c.gym_id = v_origin.gym_id
          and c.provider = v_origin.provider;
      else
        update public.gyms g
        set billing_subscription_id = v_secret
        where g.id = v_origin.gym_id
          and (
            g.billing_subscription_id is null
            or pg_catalog.btrim(g.billing_subscription_id) = v_secret
          );

        delete from private.billing_credentials c
        where c.gym_id = v_origin.gym_id
          and c.provider = v_origin.provider
          and c.vault_secret_id = v_origin.secret_id;
      end if;
    end loop;

    for v_cleared in
      select target, row_id, secret_id
      from private.billing_vault_cleared
    loop
      v_secret := private.read_billing_vault_secret(v_cleared.secret_id);

      if v_cleared.target = 'gyms' then
        update public.gyms g
        set billing_subscription_id = v_secret
        where g.id = v_cleared.row_id
          and (
            g.billing_subscription_id is null
            or pg_catalog.btrim(g.billing_subscription_id) = v_secret
          );
      else
        update public.payment_attempts pa
        set billing_key_ref = v_secret
        where pa.id = v_cleared.row_id
          and (
            pa.billing_key_ref is null
            or pg_catalog.btrim(pa.billing_key_ref) = v_secret
          );
      end if;
    end loop;

    delete from vault.secrets s
    where s.id in (
      select secret_id from private.billing_vault_origins
      union
      select secret_id from private.billing_vault_cleared
    );

    delete from private.billing_vault_origins;
    delete from private.billing_vault_cleared;

    alter table private.billing_credentials enable trigger billing_credentials_vault_key;
  exception
    when others then
      alter table private.billing_credentials enable trigger billing_credentials_vault_key;
      raise;
  end;
end;
$rollback_keys$;

revoke all on function private.rollback_billing_keys_from_vault() from public;
revoke all on function private.rollback_billing_keys_from_vault() from anon, authenticated;
revoke all on function private.rollback_billing_keys_from_vault() from service_role;

select private.copy_billing_keys_to_vault();
