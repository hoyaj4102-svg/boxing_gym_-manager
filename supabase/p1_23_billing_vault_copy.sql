-- =============================================================================
-- p1_23 Billing Vault copy (M1)
--
-- requires Founder approval before applying to production
-- Apply this file alone. Do not apply p1_24 or p1_25 in the same approval.
--
-- Copies each existing auto-billing key into its own supabase_vault secret and
-- records only the secret id. Plaintext is not deleted, nulled, or logged.
-- The copy and the match check run in one function call, so a mismatch aborts
-- that transaction and leaves no new secret from the failed call.
-- Running this file again does not create a second secret for the same gym
-- and provider.
--
-- Sources:
--   private.billing_credentials.billing_key
--   public.gyms.billing_subscription_id when the gym has no private toss row
--   (the charge fallback). A gym that already has a private row keeps that
--   private value as the source of truth.
--
-- After this file, reads try Vault first and still fall back to plaintext,
-- including the gyms column. p1_24 removes that gyms fallback.
--
-- This file does not drop a column. Deleting the Vault secrets it creates is
-- safe only while the plaintext copy still exists. See the rollback file.
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
      -- Disposable SQL tests install a vault-compatible API in the database
      -- named by scripts/run-sql-tests.sh. Any other database must have the
      -- real supabase_vault extension.
      if current_database() = 'ci_sql_tests'
         and exists (
           select 1
           from pg_proc p
           join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'vault'
             and p.proname = 'create_secret'
         ) then
        null;
      else
        raise exception 'supabase_vault extension is required';
      end if;
  end;
end
$require_vault$;

revoke all on schema vault from public;
revoke all on schema vault from anon, authenticated;
revoke all on all tables in schema vault from public;
revoke all on all tables in schema vault from anon, authenticated;

do $revoke_vault_objects$
begin
  if to_regclass('vault.secrets') is not null then
    execute 'revoke all on table vault.secrets from public';
    execute 'revoke all on table vault.secrets from anon, authenticated';
    execute 'revoke all on table vault.secrets from service_role';
  end if;
  if to_regclass('vault.decrypted_secrets') is not null then
    execute 'revoke all on table vault.decrypted_secrets from public';
    execute 'revoke all on table vault.decrypted_secrets from anon, authenticated';
    execute 'revoke all on table vault.decrypted_secrets from service_role';
  end if;
  if to_regclass('vault._shim_key') is not null then
    execute 'revoke all on table vault._shim_key from public';
    execute 'revoke all on table vault._shim_key from anon, authenticated';
    execute 'revoke all on table vault._shim_key from service_role';
  end if;
  if to_regprocedure('vault.create_secret(text, text, text)') is not null then
    execute 'revoke all on function vault.create_secret(text, text, text) from public';
    execute 'revoke all on function vault.create_secret(text, text, text) from anon, authenticated';
  end if;
  if to_regprocedure('vault.update_secret(uuid, text, text, text)') is not null then
    execute 'revoke all on function vault.update_secret(uuid, text, text, text) from public';
    execute 'revoke all on function vault.update_secret(uuid, text, text, text) from anon, authenticated';
  end if;
end
$revoke_vault_objects$;

create table if not exists private.billing_vault_secrets (
  gym_id uuid not null references public.gyms (id) on delete cascade,
  provider text not null check (provider in ('toss', 'stripe')),
  secret_id uuid not null,
  source text not null check (
    source in ('billing_credentials', 'gyms_fallback', 'payment_attempt')
  ),
  created_at timestamptz not null default now(),
  primary key (gym_id, provider),
  unique (secret_id)
);

alter table private.billing_vault_secrets enable row level security;

revoke all on table private.billing_vault_secrets from public;
revoke all on table private.billing_vault_secrets from anon, authenticated;
grant select, insert, update, delete on table private.billing_vault_secrets to service_role;

alter table private.billing_credentials
  add column if not exists vault_secret_id uuid;

create unique index if not exists billing_credentials_vault_secret_id_idx
  on private.billing_credentials (vault_secret_id)
  where vault_secret_id is not null;

revoke all on table private.billing_credentials from public;
revoke all on table private.billing_credentials from anon, authenticated;
grant select, insert, update, delete on table private.billing_credentials to service_role;

create table if not exists private.billing_vault_policy (
  id integer primary key check (id = 1),
  retire_plaintext boolean not null default false
);

insert into private.billing_vault_policy (id, retire_plaintext)
values (1, false)
on conflict (id) do nothing;

alter table private.billing_vault_policy enable row level security;

revoke all on table private.billing_vault_policy from public;
revoke all on table private.billing_vault_policy from anon, authenticated;

comment on table private.billing_vault_secrets is
  'Secret ids for auto-billing keys. The key itself lives only in Vault.';

create or replace function private.billing_vault_plaintext_retired()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select p.retire_plaintext
      from private.billing_vault_policy p
      where p.id = 1
    ),
    false
  );
$$;

revoke all on function private.billing_vault_plaintext_retired() from public;
revoke all on function private.billing_vault_plaintext_retired() from anon, authenticated;

create or replace function private.read_billing_vault_secret(p_secret_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret text;
begin
  if p_secret_id is null then
    return null;
  end if;

  select ds.decrypted_secret
  into v_secret
  from vault.decrypted_secrets ds
  where ds.id = p_secret_id;

  return nullif(btrim(v_secret), '');
end;
$$;

revoke all on function private.read_billing_vault_secret(uuid) from public;
revoke all on function private.read_billing_vault_secret(uuid) from anon, authenticated;
grant execute on function private.read_billing_vault_secret(uuid) to service_role;

create or replace function private.read_gym_vault_billing_key(
  p_gym_id uuid,
  p_provider text
)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_secret_id uuid;
begin
  select s.secret_id
  into v_secret_id
  from private.billing_vault_secrets s
  where s.gym_id = p_gym_id
    and s.provider = p_provider;

  return private.read_billing_vault_secret(v_secret_id);
end;
$$;

revoke all on function private.read_gym_vault_billing_key(uuid, text) from public;
revoke all on function private.read_gym_vault_billing_key(uuid, text) from anon, authenticated;
grant execute on function private.read_gym_vault_billing_key(uuid, text) to service_role;

create or replace function public.read_gym_billing_vault_credential(p_gym_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  return private.read_gym_vault_billing_key(p_gym_id, 'toss');
end;
$$;

revoke all on function public.read_gym_billing_vault_credential(uuid) from public;
revoke all on function public.read_gym_billing_vault_credential(uuid) from anon, authenticated;
grant execute on function public.read_gym_billing_vault_credential(uuid) to service_role;

create or replace function private.vault_copy_one(
  p_gym_id uuid,
  p_provider text,
  p_secret text,
  p_source text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_name text := 'billing_key:' || p_gym_id::text || ':' || p_provider;
  v_secret text := btrim(p_secret);
  v_secret_id uuid;
  v_current text;
begin
  if p_gym_id is null or v_secret is null or length(v_secret) = 0 then
    return;
  end if;

  if p_provider not in ('toss', 'stripe') then
    raise exception 'BILLING_PROVIDER_UNSUPPORTED';
  end if;

  if p_source not in ('billing_credentials', 'gyms_fallback', 'payment_attempt') then
    raise exception 'BILLING_VAULT_SOURCE_UNSUPPORTED';
  end if;

  select s.secret_id
  into v_secret_id
  from private.billing_vault_secrets s
  where s.gym_id = p_gym_id
    and s.provider = p_provider;

  if v_secret_id is null then
    select ds.id
    into v_secret_id
    from vault.decrypted_secrets ds
    where ds.name = v_name
    limit 1;
  end if;

  if v_secret_id is not null then
    v_current := private.read_billing_vault_secret(v_secret_id);
    if v_current is distinct from v_secret then
      raise exception 'BILLING_VAULT_COPY_MISMATCH';
    end if;

    insert into private.billing_vault_secrets (gym_id, provider, secret_id, source)
    values (p_gym_id, p_provider, v_secret_id, p_source)
    on conflict (gym_id, provider) do nothing;

    update private.billing_credentials c
    set vault_secret_id = v_secret_id
    where c.gym_id = p_gym_id
      and c.provider = p_provider
      and c.vault_secret_id is distinct from v_secret_id;
    return;
  end if;

  v_secret_id := vault.create_secret(v_secret, v_name, 'billing credential');

  insert into private.billing_vault_secrets (gym_id, provider, secret_id, source)
  values (p_gym_id, p_provider, v_secret_id, p_source);

  update private.billing_credentials c
  set vault_secret_id = v_secret_id
  where c.gym_id = p_gym_id
    and c.provider = p_provider
    and c.vault_secret_id is distinct from v_secret_id;
end;
$$;

revoke all on function private.vault_copy_one(uuid, text, text, text) from public;
revoke all on function private.vault_copy_one(uuid, text, text, text) from anon, authenticated;

create or replace function private.copy_billing_keys_to_vault()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_column boolean;
  v_source_sql text;
  v_rec record;
  v_decrypted text;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  if v_has_column then
    v_source_sql := $sql$
      select c.gym_id, c.provider, btrim(c.billing_key) as secret_value,
             'billing_credentials'::text as source
      from private.billing_credentials c
      where c.billing_key is not null
        and length(btrim(c.billing_key)) > 0
      union all
      select g.id, 'toss'::text, btrim(g.billing_subscription_id),
             'gyms_fallback'::text
      from public.gyms g
      where g.billing_provider = 'toss'
        and g.billing_subscription_id is not null
        and length(btrim(g.billing_subscription_id)) > 0
        and not exists (
          select 1
          from private.billing_credentials c
          where c.gym_id = g.id
            and c.provider = 'toss'
        )
    $sql$;
  else
    v_source_sql := $sql$
      select g.id as gym_id, 'toss'::text as provider,
             btrim(g.billing_subscription_id) as secret_value,
             'gyms_fallback'::text as source
      from public.gyms g
      where g.billing_provider = 'toss'
        and g.billing_subscription_id is not null
        and length(btrim(g.billing_subscription_id)) > 0
        and not exists (
          select 1
          from private.billing_credentials c
          where c.gym_id = g.id
            and c.provider = 'toss'
        )
    $sql$;
  end if;

  for v_rec in execute v_source_sql
  loop
    perform private.vault_copy_one(
      v_rec.gym_id,
      v_rec.provider,
      v_rec.secret_value,
      v_rec.source
    );
  end loop;

  for v_rec in execute v_source_sql
  loop
    v_decrypted := private.read_gym_vault_billing_key(v_rec.gym_id, v_rec.provider);
    if v_decrypted is distinct from v_rec.secret_value then
      raise exception 'BILLING_VAULT_COPY_MISMATCH';
    end if;
  end loop;
end;
$$;

revoke all on function private.copy_billing_keys_to_vault() from public;
revoke all on function private.copy_billing_keys_to_vault() from anon, authenticated;

create or replace function private.store_billing_credential(
  p_gym_id uuid,
  p_provider text,
  p_billing_key text
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_provider text := coalesce(nullif(btrim(p_provider), ''), 'toss');
  v_key text := btrim(p_billing_key);
  v_name text;
  v_secret_id uuid;
  v_current text;
  v_row_id uuid;
  v_has_column boolean;
  v_retire boolean;
begin
  if p_gym_id is null then
    raise exception 'GYM_ID_REQUIRED';
  end if;

  if v_provider not in ('toss', 'stripe') then
    raise exception 'BILLING_PROVIDER_UNSUPPORTED';
  end if;

  if v_key is null or length(v_key) = 0 then
    raise exception 'BILLING_CREDENTIAL_REQUIRED';
  end if;

  v_name := 'billing_key:' || p_gym_id::text || ':' || v_provider;
  v_retire := private.billing_vault_plaintext_retired();

  select s.secret_id
  into v_secret_id
  from private.billing_vault_secrets s
  where s.gym_id = p_gym_id
    and s.provider = v_provider;

  if v_secret_id is null then
    select ds.id
    into v_secret_id
    from vault.decrypted_secrets ds
    where ds.name = v_name
    limit 1;
  end if;

  if v_secret_id is not null then
    v_current := private.read_billing_vault_secret(v_secret_id);
    if v_current is distinct from v_key then
      perform vault.update_secret(v_secret_id, v_key, v_name, 'billing credential');
    end if;
  else
    v_secret_id := vault.create_secret(v_key, v_name, 'billing credential');
  end if;

  insert into private.billing_vault_secrets (gym_id, provider, secret_id, source)
  values (p_gym_id, v_provider, v_secret_id, 'billing_credentials')
  on conflict (gym_id, provider) do update
  set secret_id = excluded.secret_id;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  if v_has_column and not v_retire then
    execute $sql$
      insert into private.billing_credentials (
        gym_id, provider, billing_key, vault_secret_id
      )
      values ($1, $2, $3, $4)
      on conflict (gym_id, provider) do update
      set
        billing_key = excluded.billing_key,
        vault_secret_id = excluded.vault_secret_id,
        updated_at = now()
      returning id
    $sql$
    into v_row_id
    using p_gym_id, v_provider, v_key, v_secret_id;
  elsif v_has_column and v_retire then
    execute $sql$
      insert into private.billing_credentials (
        gym_id, provider, billing_key, vault_secret_id
      )
      values ($1, $2, null, $3)
      on conflict (gym_id, provider) do update
      set
        billing_key = null,
        vault_secret_id = excluded.vault_secret_id,
        updated_at = now()
      returning id
    $sql$
    into v_row_id
    using p_gym_id, v_provider, v_secret_id;
  else
    execute $sql$
      insert into private.billing_credentials (gym_id, provider, vault_secret_id)
      values ($1, $2, $3)
      on conflict (gym_id, provider) do update
      set
        vault_secret_id = excluded.vault_secret_id,
        updated_at = now()
      returning id
    $sql$
    into v_row_id
    using p_gym_id, v_provider, v_secret_id;
  end if;

  return v_row_id;
end;
$$;

revoke all on function private.store_billing_credential(uuid, text, text) from public;
revoke all on function private.store_billing_credential(uuid, text, text) from anon, authenticated;

create or replace function private.resolve_toss_billing_credential(p_gym_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_key text;
  v_has_column boolean;
begin
  v_key := private.read_gym_vault_billing_key(p_gym_id, 'toss');
  if v_key is not null then
    return v_key;
  end if;

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  if v_has_column then
    execute $sql$
      select btrim(c.billing_key)
      from private.billing_credentials c
      where c.gym_id = $1
        and c.provider = 'toss'
        and c.billing_key is not null
        and length(btrim(c.billing_key)) > 0
      limit 1
    $sql$
    into v_key
    using p_gym_id;

    if v_key is not null then
      return v_key;
    end if;
  end if;

  if private.billing_vault_plaintext_retired() then
    return null;
  end if;

  select btrim(g.billing_subscription_id)
  into v_key
  from public.gyms g
  where g.id = p_gym_id
    and g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and length(btrim(g.billing_subscription_id)) > 0;

  return v_key;
end;
$$;

revoke all on function private.resolve_toss_billing_credential(uuid) from public;
revoke all on function private.resolve_toss_billing_credential(uuid) from anon, authenticated;

create or replace function private.gym_has_billing_credential(p_gym_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if private.resolve_toss_billing_credential(p_gym_id) is not null then
    return true;
  end if;

  if private.billing_vault_plaintext_retired() then
    return false;
  end if;

  return exists (
    select 1
    from public.gyms g
    where g.id = p_gym_id
      and g.billing_subscription_id is not null
      and length(btrim(g.billing_subscription_id)) > 0
  );
end;
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
as $$
begin
  return private.store_billing_credential(p_gym_id, p_provider, p_billing_key);
end;
$$;

revoke all on function public.upsert_gym_billing_credential(uuid, text, text) from public;
revoke all on function public.upsert_gym_billing_credential(uuid, text, text) from anon, authenticated;
grant execute on function public.upsert_gym_billing_credential(uuid, text, text) to service_role;

create or replace function public.read_gym_billing_credential(p_gym_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select private.resolve_toss_billing_credential(p_gym_id);
$$;

revoke all on function public.read_gym_billing_credential(uuid) from public;
revoke all on function public.read_gym_billing_credential(uuid) from anon, authenticated;
grant execute on function public.read_gym_billing_credential(uuid) to service_role;

-- Activation still accepts a legacy attempt value, stores it through Vault,
-- and clears the attempt column. The rest of activation is unchanged.
create or replace function public.activate_payment_attempt_core(
  p_attempt_id uuid,
  p_is_recovery boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = private, public
as $$
declare
  v_attempt public.payment_attempts%rowtype;
  v_error_message text;
  v_gym_auto_renew boolean;
  v_gym_subscription_status text;
  v_gym_complimentary boolean;
  v_next_subscription_status text;
  v_next_auto_renew boolean;
begin
  select * into v_attempt
  from public.payment_attempts
  where id = p_attempt_id
  for update;

  if not found then
    raise exception 'PAYMENT_ATTEMPT_NOT_FOUND';
  end if;

  if v_attempt.provider = 'toss'
     and v_attempt.billing_key_ref is not null
     and length(btrim(v_attempt.billing_key_ref)) > 0 then
    perform private.store_billing_credential(
      v_attempt.gym_id,
      'toss',
      btrim(v_attempt.billing_key_ref)
    );

    update public.payment_attempts
    set billing_key_ref = null
    where id = v_attempt.id;
  end if;

  if v_attempt.status = 'completed'
     and v_attempt.activation_status = 'succeeded' then
    return jsonb_build_object(
      'ok', true,
      'already_completed', true,
      'payment_attempt_id', v_attempt.id
    );
  end if;

  if v_attempt.status not in ('charge_succeeded', 'activation_pending', 'activation_failed', 'recovery_pending') then
    raise exception 'PAYMENT_ATTEMPT_NOT_RECOVERABLE:%', v_attempt.status;
  end if;

  if v_attempt.payment_key is null then
    raise exception 'PAYMENT_KEY_REQUIRED';
  end if;

  if v_attempt.target_period_start is null then
    raise exception 'TARGET_PERIOD_START_REQUIRED';
  end if;

  if v_attempt.target_period_end is null then
    raise exception 'TARGET_PERIOD_END_REQUIRED';
  end if;

  update public.payment_attempts
  set
    status = 'activation_pending',
    activation_status = 'pending',
    recovery_status = case when p_is_recovery then 'pending' else 'none' end,
    error_code = null,
    error_message = null
  where id = v_attempt.id;

  begin
    select auto_renew, subscription_status, complimentary_pro
    into v_gym_auto_renew, v_gym_subscription_status, v_gym_complimentary
    from public.gyms
    where id = v_attempt.gym_id
    for update;

    if not found then
      raise exception 'GYM_NOT_FOUND';
    end if;

    v_next_subscription_status := case
      when v_attempt.payment_type = 'auto_renewal'
           and v_gym_subscription_status = 'canceled' then 'canceled'
      else 'active'
    end;

    v_next_auto_renew := case
      when coalesce(v_gym_complimentary, false) then false
      when v_attempt.payment_type = 'auto_renewal'
           and (v_gym_subscription_status = 'canceled' or v_gym_auto_renew = false) then false
      else true
    end;

    perform set_config('app.allow_billing_update', '1', true);

    update public.gyms
    set
      plan_code = 'pro',
      member_limit = -1,
      subscription_status = v_next_subscription_status,
      current_period_end = case
        when current_period_end is null
          or current_period_end < v_attempt.target_period_end then v_attempt.target_period_end
        else current_period_end
      end,
      billing_provider = v_attempt.provider,
      billing_customer_id = coalesce(v_attempt.customer_key, billing_customer_id),
      auto_renew = v_next_auto_renew,
      updated_at = now()
    where id = v_attempt.gym_id;

    insert into public.subscriptions (
      gym_id,
      plan_code,
      status,
      provider,
      provider_ref,
      amount_krw,
      started_at,
      ends_at,
      raw
    )
    values (
      v_attempt.gym_id,
      'pro',
      'active',
      v_attempt.provider,
      v_attempt.payment_key,
      v_attempt.amount_krw,
      v_attempt.target_period_start,
      v_attempt.target_period_end,
      private.redact_sensitive_payload(jsonb_build_object(
        'activated_from_payment_attempt', v_attempt.id,
        'activation_mode', case when p_is_recovery then 'recovery' else 'normal' end,
        'payment_key', v_attempt.payment_key,
        'provider_response', coalesce(v_attempt.provider_response, '{}'::jsonb)
      ))
    );

    update public.payment_attempts
    set
      status = 'completed',
      activation_status = 'succeeded',
      recovery_status = case when p_is_recovery then 'completed' else 'none' end,
      activated_at = coalesce(activated_at, now()),
      recovered_at = case when p_is_recovery then now() else recovered_at end,
      error_code = null,
      error_message = null
    where id = v_attempt.id;

    return jsonb_build_object(
      'ok', true,
      'already_completed', false,
      'payment_attempt_id', v_attempt.id,
      'target_period_start', v_attempt.target_period_start,
      'target_period_end', v_attempt.target_period_end
    );
  exception when others then
    v_error_message := left(sqlerrm, 500);

    update public.payment_attempts
    set
      status = 'activation_failed',
      activation_status = 'failed',
      recovery_status = case when p_is_recovery then 'failed' else recovery_status end,
      error_code = sqlstate,
      error_message = v_error_message
    where id = v_attempt.id;

    return jsonb_build_object(
      'ok', false,
      'payment_attempt_id', v_attempt.id,
      'error_code', sqlstate,
      'error_message', v_error_message
    );
  end;
end;
$$;

revoke all on function public.activate_payment_attempt_core(uuid, boolean) from public;
revoke all on function public.activate_payment_attempt_core(uuid, boolean) from anon, authenticated;
grant execute on function public.activate_payment_attempt_core(uuid, boolean) to service_role;

create or replace function private.rollback_billing_vault_copy()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
  v_plain text;
  v_has_column boolean;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  for v_rec in
    select s.gym_id, s.provider, s.secret_id, s.source
    from private.billing_vault_secrets s
  loop
    v_plain := null;

    if v_has_column then
      execute $sql$
        select btrim(c.billing_key)
        from private.billing_credentials c
        where c.gym_id = $1
          and c.provider = $2
          and c.billing_key is not null
          and length(btrim(c.billing_key)) > 0
      $sql$
      into v_plain
      using v_rec.gym_id, v_rec.provider;
    end if;

    if v_plain is null and v_rec.source = 'gyms_fallback' then
      select btrim(g.billing_subscription_id)
      into v_plain
      from public.gyms g
      where g.id = v_rec.gym_id
        and g.billing_subscription_id is not null
        and length(btrim(g.billing_subscription_id)) > 0;
    end if;

    if v_plain is distinct from private.read_billing_vault_secret(v_rec.secret_id) then
      raise exception 'BILLING_VAULT_ROLLBACK_UNSAFE';
    end if;
  end loop;

  delete from vault.secrets vs
  using private.billing_vault_secrets s
  where vs.id = s.secret_id;

  update private.billing_credentials
  set vault_secret_id = null
  where vault_secret_id is not null;

  delete from private.billing_vault_secrets;
end;
$$;

revoke all on function private.rollback_billing_vault_copy() from public;
revoke all on function private.rollback_billing_vault_copy() from anon, authenticated;

-- Copy existing keys. Plaintext stays. A mismatch raises and rolls this call back.
select private.copy_billing_keys_to_vault();
