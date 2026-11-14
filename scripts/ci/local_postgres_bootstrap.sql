-- Disposable local/CI stand-in for the hosted auth schema and roles.
-- Apply only to a temporary database created by scripts/run-sql-tests.sh.
-- Not for production.

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then
    create role anon nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    create role authenticated nologin;
  end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then
    create role service_role nologin bypassrls;
  end if;
end
$$;

create schema if not exists auth;

create table if not exists auth.users (
  id uuid primary key,
  instance_id uuid,
  aud text,
  role text,
  email text,
  encrypted_password text,
  email_confirmed_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  raw_app_meta_data jsonb not null default '{}'::jsonb,
  raw_user_meta_data jsonb not null default '{}'::jsonb
);

create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid;
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
  select coalesce(
    nullif(current_setting('request.jwt.claim.role', true), ''),
    current_user
  );
$$;

-- Disposable stand-in for supabase_vault. Production migrations create the
-- real extension. This block never stores a real billing key: the passphrase
-- is random and lives only in this temporary database.
do $vault_shim$
begin
  if exists (select 1 from pg_extension where extname = 'supabase_vault') then
    return;
  end if;

  create extension if not exists pgcrypto;

  create schema if not exists vault;

  create table if not exists vault.secrets (
    id uuid primary key default gen_random_uuid(),
    name text unique,
    description text not null default '',
    secret text not null,
    key_id uuid,
    nonce bytea,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now()
  );

  create table if not exists vault._shim_key (
    id integer primary key,
    passphrase text not null
  );

  insert into vault._shim_key (id, passphrase)
  values (1, encode(gen_random_bytes(32), 'hex'))
  on conflict (id) do nothing;

  create or replace function vault.create_secret(
    new_secret text,
    new_name text default null,
    new_description text default ''
  )
  returns uuid
  language plpgsql
  set search_path = pg_catalog, public
  as $create_secret$
  declare
    v_id uuid := gen_random_uuid();
    v_pass text;
  begin
    select passphrase into v_pass from vault._shim_key where id = 1;
    insert into vault.secrets (id, name, description, secret)
    values (
      v_id,
      new_name,
      coalesce(new_description, ''),
      encode(pgp_sym_encrypt(new_secret, v_pass), 'base64')
    );
    return v_id;
  end;
  $create_secret$;

  create or replace function vault.update_secret(
    secret_id uuid,
    new_secret text default null,
    new_name text default null,
    new_description text default null
  )
  returns void
  language plpgsql
  set search_path = pg_catalog, public
  as $update_secret$
  declare
    v_pass text;
  begin
    select passphrase into v_pass from vault._shim_key where id = 1;
    update vault.secrets
    set
      secret = case
        when new_secret is null then secret
        else encode(pgp_sym_encrypt(new_secret, v_pass), 'base64')
      end,
      name = coalesce(new_name, name),
      description = coalesce(new_description, description),
      updated_at = now()
    where id = secret_id;
    if not found then
      raise exception 'VAULT_SECRET_NOT_FOUND';
    end if;
  end;
  $update_secret$;

  create or replace view vault.decrypted_secrets as
  select
    s.id,
    s.name,
    s.description,
    s.secret,
    pgp_sym_decrypt(decode(s.secret, 'base64'), k.passphrase) as decrypted_secret,
    s.key_id,
    s.nonce,
    s.created_at,
    s.updated_at
  from vault.secrets s
  cross join vault._shim_key k
  where k.id = 1;

  revoke all on schema vault from public;
  revoke all on all tables in schema vault from public;
  revoke all on vault._shim_key from public;
  revoke all on vault.decrypted_secrets from public;
  revoke all on function vault.create_secret(text, text, text) from public;
  revoke all on function vault.update_secret(uuid, text, text, text) from public;
end
$vault_shim$;
