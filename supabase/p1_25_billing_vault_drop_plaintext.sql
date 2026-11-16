-- =============================================================================
-- p1_25 Drop billing plaintext column (M3)
--
-- requires Founder approval before applying to production
-- Apply only after p1_24. Confirm no private.billing_credentials.billing_key
-- value is still non-null. This file aborts with
-- BILLING_VAULT_PLAINTEXT_REMAINS when any value is still present, so a key
-- that never reached Vault is not destroyed.
--
-- Drops private.billing_credentials.billing_key only.
-- Does not drop public.gyms.billing_subscription_id,
-- public.payment_attempts.billing_key_ref, or public.subscriptions.provider_ref.
-- Those columns still hold non-secret provider references. p1_24 documents
-- which values were nulled and which were kept.
--
-- Irreversible point: after this drop, the plaintext copy is gone. The
-- rollback can recreate the column from Vault only while those secrets still
-- decrypt. Deleting a Vault secret, or losing the Vault key, after this file
-- cannot be repaired from the database. Do not delete Vault secrets as part
-- of this step.
-- =============================================================================

create or replace function private.drop_billing_plaintext_column()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_has_column boolean;
  v_remaining boolean;
begin
  select exists (
    select 1
    from information_schema.columns
    where table_schema = 'private'
      and table_name = 'billing_credentials'
      and column_name = 'billing_key'
  )
  into v_has_column;

  if not v_has_column then
    return;
  end if;

  execute $sql$
    select exists (
      select 1
      from private.billing_credentials
      where billing_key is not null
        and length(btrim(billing_key)) > 0
    )
  $sql$
  into v_remaining;

  if v_remaining then
    raise exception 'BILLING_VAULT_PLAINTEXT_REMAINS';
  end if;

  execute 'alter table private.billing_credentials drop column billing_key';
end;
$$;

revoke all on function private.drop_billing_plaintext_column() from public;
revoke all on function private.drop_billing_plaintext_column() from anon, authenticated;

create or replace function private.rollback_billing_vault_drop()
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

  if not v_has_column then
    execute 'alter table private.billing_credentials add column billing_key text';
  else
    execute 'alter table private.billing_credentials alter column billing_key drop not null';
  end if;

  select exists (
    select 1
    from private.billing_vault_secrets s
    where private.read_billing_vault_secret(s.secret_id) is null
  )
  into v_missing;

  if v_missing then
    raise exception 'BILLING_VAULT_ROLLBACK_INCOMPLETE';
  end if;

  insert into private.billing_credentials (gym_id, provider, vault_secret_id)
  select s.gym_id, s.provider, s.secret_id
  from private.billing_vault_secrets s
  where not exists (
    select 1
    from private.billing_credentials c
    where c.gym_id = s.gym_id
      and c.provider = s.provider
  );

  execute $sql$
    update private.billing_credentials c
    set
      billing_key = private.read_gym_vault_billing_key(c.gym_id, c.provider),
      vault_secret_id = coalesce(c.vault_secret_id, s.secret_id)
    from private.billing_vault_secrets s
    where s.gym_id = c.gym_id
      and s.provider = c.provider
  $sql$;

  update private.billing_vault_policy
  set retire_plaintext = true
  where id = 1;
end;
$$;

revoke all on function private.rollback_billing_vault_drop() from public;
revoke all on function private.rollback_billing_vault_drop() from anon, authenticated;

select private.drop_billing_plaintext_column();
