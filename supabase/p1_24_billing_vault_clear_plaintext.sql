-- =============================================================================
-- p1_24 Clear Vault-confirmed billing plaintext (M2)
--
-- requires Founder approval before applying to production
-- Apply only after p1_23 has been checked. Do not apply p1_25 in the same
-- approval.
--
-- What this file changes:
--   Nulls plaintext only when the decrypted Vault secret matches it.
--   A value that is not in Vault is left in place (skipped). The backfill
--   raises BILLING_VAULT_PLAINTEXT_NOT_VAULTED instead of retiring the gyms
--   fallback when a charge source is still missing from Vault.
--   After a successful run, reads no longer use public.gyms.billing_subscription_id.
--   New credential writes go to Vault and do not store a new plaintext key.
--
-- Column decisions (no production values are read into this file):
--   private.billing_credentials.billing_key
--     The auto-billing key. Real secret. Nulled when Vault matches.
--     p1_25 drops the column. It is made nullable here so the null is legal.
--   public.gyms.billing_subscription_id
--     Mixed. Toss charge fallback stored the billing key here when no private
--     row existed. Stripe and other writers store a provider subscription id.
--     Null only when the value equals the Vault billing key. Any other value
--     is a non-secret provider reference and is kept. The column is not dropped.
--   public.payment_attempts.billing_key_ref
--     Legacy secret when it holds the billing key (new claims already insert
--     null). Null only when it equals the Vault billing key. A different value
--     is not in Vault, so it is skipped and kept. The column stays because the
--     claim result still uses this name and unmatched legacy values may remain.
--   public.subscriptions.provider_ref
--     Non-secret provider reference (payment id or subscription id). Kept.
--     Null only when it exactly equals the Vault billing key, which means the
--     secret was stored in the reference column. Do not move payment ids into
--     Vault.
--
-- Irreversible if the Vault secret is deleted after this file nulls the
-- plaintext. The rollback restores nulled values from Vault and turns the
-- gyms fallback back on. It cannot invent a key Vault no longer has.
-- Do not run the p1_23 rollback after this file: that rollback refuses when
-- plaintext no longer matches Vault.
-- =============================================================================

do $drop_not_null$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  ) then
    execute 'alter table private.billing_credentials alter column billing_key drop not null';
  end if;
end
$drop_not_null$;

create table if not exists private.billing_vault_cleared (
  id bigint generated always as identity primary key,
  target text not null check (
    target in (
      'billing_credentials',
      'gyms',
      'payment_attempts',
      'subscriptions'
    )
  ),
  row_id uuid not null,
  gym_id uuid,
  provider text,
  cleared_at timestamptz not null default now()
);

alter table private.billing_vault_cleared enable row level security;

revoke all on table private.billing_vault_cleared from public;
revoke all on table private.billing_vault_cleared from anon, authenticated;

create or replace function private.copy_attempt_billing_keys_to_vault()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rec record;
  v_decrypted text;
begin
  for v_rec in
    select distinct on (pa.gym_id)
      pa.gym_id,
      btrim(pa.billing_key_ref) as secret_value
    from public.payment_attempts pa
    where pa.provider = 'toss'
      and pa.billing_key_ref is not null
      and length(btrim(pa.billing_key_ref)) > 0
      and not exists (
        select 1
        from private.billing_vault_secrets s
        where s.gym_id = pa.gym_id
          and s.provider = 'toss'
      )
    order by pa.gym_id, pa.updated_at desc nulls last, pa.created_at desc
  loop
    perform private.vault_copy_one(
      v_rec.gym_id,
      'toss',
      v_rec.secret_value,
      'payment_attempt'
    );
  end loop;

  for v_rec in
    select distinct on (pa.gym_id)
      pa.gym_id,
      btrim(pa.billing_key_ref) as secret_value
    from public.payment_attempts pa
    where pa.provider = 'toss'
      and pa.billing_key_ref is not null
      and length(btrim(pa.billing_key_ref)) > 0
      and not exists (
        select 1
        from private.billing_credentials c
        where c.gym_id = pa.gym_id
          and c.provider = 'toss'
          and c.vault_secret_id is not null
      )
      and exists (
        select 1
        from private.billing_vault_secrets s
        where s.gym_id = pa.gym_id
          and s.provider = 'toss'
          and s.source = 'payment_attempt'
      )
    order by pa.gym_id, pa.updated_at desc nulls last, pa.created_at desc
  loop
    v_decrypted := private.read_gym_vault_billing_key(v_rec.gym_id, 'toss');
    if v_decrypted is distinct from v_rec.secret_value then
      raise exception 'BILLING_VAULT_COPY_MISMATCH';
    end if;
  end loop;
end;
$$;

revoke all on function private.copy_attempt_billing_keys_to_vault() from public;
revoke all on function private.copy_attempt_billing_keys_to_vault() from anon, authenticated;

create or replace function private.assert_billing_plaintext_vaulted()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_column boolean;
  v_missing boolean;
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
    execute $sql$
      select exists (
        select 1
        from private.billing_credentials c
        where c.billing_key is not null
          and length(btrim(c.billing_key)) > 0
          and private.read_gym_vault_billing_key(c.gym_id, c.provider)
            is distinct from btrim(c.billing_key)
      )
    $sql$
    into v_missing;

    if v_missing then
      raise exception 'BILLING_VAULT_PLAINTEXT_NOT_VAULTED';
    end if;
  end if;

  select exists (
    select 1
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
      and private.read_gym_vault_billing_key(g.id, 'toss')
        is distinct from btrim(g.billing_subscription_id)
  )
  into v_missing;

  if v_missing then
    raise exception 'BILLING_VAULT_PLAINTEXT_NOT_VAULTED';
  end if;
end;
$$;

revoke all on function private.assert_billing_plaintext_vaulted() from public;
revoke all on function private.assert_billing_plaintext_vaulted() from anon, authenticated;

create or replace function private.clear_vault_confirmed_billing_plaintext()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_column boolean;
begin
  perform set_config('app.allow_billing_update', '1', true);

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
      with updated as (
        update private.billing_credentials c
        set billing_key = null
        from private.billing_vault_secrets s
        where s.gym_id = c.gym_id
          and s.provider = c.provider
          and c.billing_key is not null
          and length(btrim(c.billing_key)) > 0
          and private.read_gym_vault_billing_key(c.gym_id, c.provider) = btrim(c.billing_key)
        returning c.id, c.gym_id, c.provider
      )
      insert into private.billing_vault_cleared (target, row_id, gym_id, provider)
      select 'billing_credentials', id, gym_id, provider
      from updated
    $sql$;
  end if;

  with updated as (
    update public.gyms g
    set billing_subscription_id = null
    where g.billing_provider = 'toss'
      and g.billing_subscription_id is not null
      and length(btrim(g.billing_subscription_id)) > 0
      and private.read_gym_vault_billing_key(g.id, 'toss') = btrim(g.billing_subscription_id)
    returning g.id
  )
  insert into private.billing_vault_cleared (target, row_id, gym_id, provider)
  select 'gyms', id, id, 'toss'
  from updated;

  with updated as (
    update public.payment_attempts pa
    set billing_key_ref = null
    where pa.provider = 'toss'
      and pa.billing_key_ref is not null
      and length(btrim(pa.billing_key_ref)) > 0
      and private.read_gym_vault_billing_key(pa.gym_id, 'toss') = btrim(pa.billing_key_ref)
    returning pa.id, pa.gym_id
  )
  insert into private.billing_vault_cleared (target, row_id, gym_id, provider)
  select 'payment_attempts', id, gym_id, 'toss'
  from updated;

  with updated as (
    update public.subscriptions s
    set provider_ref = null
    where s.provider = 'toss'
      and s.provider_ref is not null
      and length(btrim(s.provider_ref)) > 0
      and private.read_gym_vault_billing_key(s.gym_id, 'toss') = btrim(s.provider_ref)
    returning s.id, s.gym_id
  )
  insert into private.billing_vault_cleared (target, row_id, gym_id, provider)
  select 'subscriptions', id, gym_id, 'toss'
  from updated;
end;
$$;

revoke all on function private.clear_vault_confirmed_billing_plaintext() from public;
revoke all on function private.clear_vault_confirmed_billing_plaintext() from anon, authenticated;

create or replace function private.backfill_billing_credentials()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform set_config('app.allow_billing_update', '1', true);
  perform private.copy_billing_keys_to_vault();
  perform private.copy_attempt_billing_keys_to_vault();
  perform private.assert_billing_plaintext_vaulted();
  perform private.clear_vault_confirmed_billing_plaintext();

  update public.checkout_sessions
  set raw = private.redact_sensitive_payload(raw)
  where raw is not null
    and raw is distinct from private.redact_sensitive_payload(raw);

  update public.payment_attempts
  set provider_response = private.redact_sensitive_payload(provider_response)
  where provider_response is not null
    and provider_response is distinct from private.redact_sensitive_payload(provider_response);

  update public.subscriptions
  set raw = private.redact_sensitive_payload(raw)
  where raw is not null
    and raw is distinct from private.redact_sensitive_payload(raw);

  update private.billing_vault_policy
  set retire_plaintext = true
  where id = 1;
end;
$$;

revoke all on function private.backfill_billing_credentials() from public;
revoke all on function private.backfill_billing_credentials() from anon, authenticated;

create or replace function private.rollback_billing_vault_clear()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_column boolean;
  v_needs_column boolean;
begin
  perform set_config('app.allow_billing_update', '1', true);

  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  select exists (
    select 1
    from private.billing_vault_cleared
    where target = 'billing_credentials'
  )
  into v_needs_column;

  if v_needs_column and not v_has_column then
    raise exception 'BILLING_VAULT_ROLLBACK_NEEDS_COLUMN';
  end if;

  if v_has_column then
    execute $sql$
      update private.billing_credentials c
      set billing_key = private.read_gym_vault_billing_key(c.gym_id, c.provider)
      from private.billing_vault_cleared cleared
      where cleared.target = 'billing_credentials'
        and cleared.row_id = c.id
        and private.read_gym_vault_billing_key(c.gym_id, c.provider) is not null
    $sql$;
  end if;

  update public.gyms g
  set billing_subscription_id = private.read_gym_vault_billing_key(g.id, 'toss')
  from private.billing_vault_cleared cleared
  where cleared.target = 'gyms'
    and cleared.row_id = g.id
    and private.read_gym_vault_billing_key(g.id, 'toss') is not null;

  update public.payment_attempts pa
  set billing_key_ref = private.read_gym_vault_billing_key(pa.gym_id, 'toss')
  from private.billing_vault_cleared cleared
  where cleared.target = 'payment_attempts'
    and cleared.row_id = pa.id
    and private.read_gym_vault_billing_key(pa.gym_id, 'toss') is not null;

  update public.subscriptions s
  set provider_ref = private.read_gym_vault_billing_key(s.gym_id, 'toss')
  from private.billing_vault_cleared cleared
  where cleared.target = 'subscriptions'
    and cleared.row_id = s.id
    and private.read_gym_vault_billing_key(s.gym_id, 'toss') is not null;

  delete from private.billing_vault_cleared;

  update private.billing_vault_policy
  set retire_plaintext = false
  where id = 1;
end;
$$;

revoke all on function private.rollback_billing_vault_clear() from public;
revoke all on function private.rollback_billing_vault_clear() from anon, authenticated;

-- Copies anything still missing, refuses charge sources that are not in Vault,
-- then nulls only confirmed plaintext and retires the gyms fallback.
select private.backfill_billing_credentials();
