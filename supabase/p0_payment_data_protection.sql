-- =============================================================================
-- Payment data handling
--
-- Idempotent. Keeps charge amounts, claim limits, and renewal timing the same.
-- Does not enable or edit the recurring charge scheduler.
--
-- Run after the existing billing SQL files, in the SQL editor.
-- Recommended order: this file, then the expired-plan claim SQL, then functions.
-- The two SQL files also apply safely in the other order, and either file can
-- be run again. Do not apply this file to production until Founder approval.
--
-- The final section is marked:
-- requires Founder approval before applying to production
--
-- claim_initial_billing_attempt is intentionally left unchanged.
-- =============================================================================

create schema if not exists private;

revoke all on schema private from public;
revoke all on schema private from anon, authenticated;
grant usage on schema private to service_role;

create table if not exists private.billing_credentials (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  provider text not null default 'toss'
    check (provider in ('toss', 'stripe')),
  billing_key text not null check (length(btrim(billing_key)) > 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (gym_id, provider)
);

create index if not exists billing_credentials_gym_id_idx
  on private.billing_credentials (gym_id);

alter table private.billing_credentials enable row level security;

revoke all on table private.billing_credentials from public;
revoke all on table private.billing_credentials from anon, authenticated;
grant select, insert, update, delete on table private.billing_credentials to service_role;

comment on schema private is
  'Not exposed through the Data API. Do not add this schema to exposed schemas.';

create or replace function private.redact_sensitive_payload(p_value jsonb)
returns jsonb
language plpgsql
immutable
set search_path = private, public
as $$
declare
  v_type text;
  v_key text;
  v_item jsonb;
  v_result jsonb;
  v_normalized text;
  v_sensitive text[] := array[
    'authkey',
    'authorization',
    'billingkey',
    'card',
    'cardno',
    'cardnumber',
    'customeremail',
    'customeridentitynumber',
    'customerkey',
    'customermobilephone',
    'customername',
    'secret',
    'secretkey'
  ];
begin
  if p_value is null or jsonb_typeof(p_value) = 'null' then
    return p_value;
  end if;

  v_type := jsonb_typeof(p_value);

  if v_type = 'array' then
    v_result := '[]'::jsonb;
    for v_item in
      select value
      from jsonb_array_elements(p_value)
    loop
      v_result := v_result || jsonb_build_array(private.redact_sensitive_payload(v_item));
    end loop;
    return v_result;
  end if;

  if v_type = 'object' then
    v_result := '{}'::jsonb;
    for v_key in
      select jsonb_object_keys(p_value)
    loop
      v_normalized := lower(regexp_replace(v_key, '[_\-\s]', '', 'g'));
      if v_normalized = any (v_sensitive) then
        v_result := v_result || jsonb_build_object(v_key, '[REDACTED]');
      else
        v_result := v_result || jsonb_build_object(
          v_key,
          private.redact_sensitive_payload(p_value -> v_key)
        );
      end if;
    end loop;
    return v_result;
  end if;

  if v_type = 'string'
     and btrim(p_value #>> '{}') ~ '^([0-9][ -]?){13,19}$' then
    return to_jsonb('[REDACTED]'::text);
  end if;

  return p_value;
end;
$$;

revoke all on function private.redact_sensitive_payload(jsonb) from public;
revoke all on function private.redact_sensitive_payload(jsonb) from anon, authenticated;

create or replace function private.redact_payment_row()
returns trigger
language plpgsql
security definer
set search_path = private, public
as $$
begin
  if tg_table_name = 'checkout_sessions' then
    new.raw := private.redact_sensitive_payload(coalesce(new.raw, '{}'::jsonb));
  elsif tg_table_name = 'payment_attempts' then
    new.provider_response := private.redact_sensitive_payload(
      coalesce(new.provider_response, '{}'::jsonb)
    );
  elsif tg_table_name = 'subscriptions' then
    new.raw := private.redact_sensitive_payload(coalesce(new.raw, '{}'::jsonb));
  end if;

  return new;
end;
$$;

revoke all on function private.redact_payment_row() from public;
revoke all on function private.redact_payment_row() from anon, authenticated;

drop trigger if exists checkout_sessions_redact_payload on public.checkout_sessions;
create trigger checkout_sessions_redact_payload
before insert or update of raw on public.checkout_sessions
for each row
execute function private.redact_payment_row();

drop trigger if exists payment_attempts_redact_payload on public.payment_attempts;
create trigger payment_attempts_redact_payload
before insert or update of provider_response on public.payment_attempts
for each row
execute function private.redact_payment_row();

drop trigger if exists subscriptions_redact_payload on public.subscriptions;
create trigger subscriptions_redact_payload
before insert or update of raw on public.subscriptions
for each row
execute function private.redact_payment_row();

create or replace function private.resolve_toss_billing_credential(p_gym_id uuid)
returns text
language sql
stable
security definer
set search_path = private, public
as $$
  select coalesce(
    (
      select c.billing_key
      from private.billing_credentials c
      where c.gym_id = p_gym_id
        and c.provider = 'toss'
        and length(btrim(c.billing_key)) > 0
      limit 1
    ),
    (
      select g.billing_subscription_id
      from public.gyms g
      where g.id = p_gym_id
        and g.billing_provider = 'toss'
        and g.billing_subscription_id is not null
        and length(btrim(g.billing_subscription_id)) > 0
    )
  );
$$;

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
set search_path = private, public
as $$
declare
  v_id uuid;
  v_provider text := coalesce(nullif(btrim(p_provider), ''), 'toss');
  v_billing_key text := btrim(p_billing_key);
begin
  if p_gym_id is null then
    raise exception 'GYM_ID_REQUIRED';
  end if;

  if v_provider not in ('toss', 'stripe') then
    raise exception 'BILLING_PROVIDER_UNSUPPORTED';
  end if;

  if v_billing_key is null or length(v_billing_key) = 0 then
    raise exception 'BILLING_CREDENTIAL_REQUIRED';
  end if;

  insert into private.billing_credentials (
    gym_id,
    provider,
    billing_key
  )
  values (
    p_gym_id,
    v_provider,
    v_billing_key
  )
  on conflict (gym_id, provider) do update
  set
    billing_key = excluded.billing_key,
    updated_at = now()
  returning id into v_id;

  return v_id;
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
set search_path = private, public
as $$
  select private.resolve_toss_billing_credential(p_gym_id);
$$;

revoke all on function public.read_gym_billing_credential(uuid) from public;
revoke all on function public.read_gym_billing_credential(uuid) from anon, authenticated;
grant execute on function public.read_gym_billing_credential(uuid) to service_role;

-- Owner-role clients keep access to non-sensitive columns. Credential columns
-- and stored provider payloads are not included.
revoke select on table public.gyms from public;
revoke select on table public.gyms from anon, authenticated;
grant select (
  id,
  name,
  owner_name,
  phone,
  created_at,
  plan_code,
  member_limit,
  subscription_status,
  trial_ends_at,
  current_period_end,
  billing_provider,
  billing_customer_id,
  auto_renew,
  updated_at
) on table public.gyms to anon, authenticated;

revoke select on table public.payment_attempts from public;
revoke select on table public.payment_attempts from anon, authenticated;
grant select (
  id,
  gym_id,
  user_id,
  provider,
  payment_type,
  billing_interval,
  amount_krw,
  currency,
  order_id,
  payment_key,
  customer_key,
  target_period_start,
  target_period_end,
  status,
  activation_status,
  recovery_status,
  error_code,
  error_message,
  activated_at,
  recovered_at,
  created_at,
  updated_at
) on table public.payment_attempts to anon, authenticated;

revoke select on table public.checkout_sessions from public;
revoke select on table public.checkout_sessions from anon, authenticated;
grant select (
  id,
  gym_id,
  user_id,
  provider,
  "interval",
  amount_krw,
  amount_usd_cents,
  currency,
  status,
  order_id,
  provider_session_id,
  success_url,
  fail_url,
  created_at,
  completed_at
) on table public.checkout_sessions to anon, authenticated;

revoke select on table public.subscriptions from public;
revoke select on table public.subscriptions from anon, authenticated;
grant select (
  id,
  gym_id,
  plan_code,
  status,
  provider,
  amount_krw,
  started_at,
  ends_at,
  created_at
) on table public.subscriptions to anon, authenticated;

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
    insert into private.billing_credentials (
      gym_id,
      provider,
      billing_key
    )
    values (
      v_attempt.gym_id,
      'toss',
      btrim(v_attempt.billing_key_ref)
    )
    on conflict (gym_id, provider) do update
    set
      billing_key = excluded.billing_key,
      updated_at = now()
    where private.billing_credentials.billing_key is distinct from excluded.billing_key;

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
    select auto_renew, subscription_status
    into v_gym_auto_renew, v_gym_subscription_status
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

create or replace function public.claim_due_toss_subscription_charges(
  p_now timestamptz default now(),
  p_limit integer default 50,
  p_amount_krw integer default 10000
)
returns table (
  payment_attempt_id uuid,
  gym_id uuid,
  user_id uuid,
  order_id text,
  customer_key text,
  billing_key_ref text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  amount_krw integer
)
language sql
security definer
set search_path = private, public
as $$
  with locked_due_gyms as (
    select
      g.id as gym_id,
      owner_profile.id as user_id,
      g.billing_customer_id as customer_key,
      private.resolve_toss_billing_credential(g.id) as billing_key_ref,
      g.current_period_end as target_period_start
    from public.gyms g
    left join lateral (
      select p.id
      from public.profiles p
      where p.gym_id = g.id
      order by p.created_at asc
      limit 1
    ) owner_profile on true
    where g.billing_provider = 'toss'
      and g.auto_renew = true
      and g.subscription_status = 'active'
      and g.billing_customer_id is not null
      and private.resolve_toss_billing_credential(g.id) is not null
      and g.current_period_end is not null
      and g.current_period_end <= p_now
    order by g.current_period_end asc, g.id asc
    limit greatest(least(coalesce(p_limit, 50), 100), 1)
    for update of g skip locked
  ),
  claim_rows as (
    select
      gen_random_uuid() as payment_attempt_id,
      gym_id,
      user_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      public.billing_period_end(target_period_start, 'monthly') as target_period_end,
      coalesce(p_amount_krw, 10000) as amount_krw
    from locked_due_gyms
  ),
  inserted_attempts as (
    insert into public.payment_attempts (
      id,
      gym_id,
      user_id,
      provider,
      payment_type,
      billing_interval,
      amount_krw,
      currency,
      order_id,
      customer_key,
      billing_key_ref,
      target_period_start,
      target_period_end,
      status,
      activation_status,
      recovery_status,
      provider_response
    )
    select
      cr.payment_attempt_id,
      cr.gym_id,
      cr.user_id,
      'toss',
      'auto_renewal',
      'monthly',
      cr.amount_krw,
      'KRW',
      'toss_renew_' || replace(cr.payment_attempt_id::text, '-', ''),
      cr.customer_key,
      null::text,
      cr.target_period_start,
      cr.target_period_end,
      'initiated',
      'not_started',
      'none',
      jsonb_build_object('mode', 'auto_renew_claim')
    from claim_rows cr
    on conflict do nothing
    returning
      id,
      gym_id,
      user_id,
      order_id,
      customer_key,
      target_period_start,
      target_period_end,
      amount_krw
  )
  select
    ia.id as payment_attempt_id,
    ia.gym_id,
    ia.user_id,
    ia.order_id,
    ia.customer_key,
    cr.billing_key_ref,
    ia.target_period_start,
    ia.target_period_end,
    ia.amount_krw
  from inserted_attempts ia
  join claim_rows cr on cr.payment_attempt_id = ia.id
  order by ia.target_period_start asc, ia.gym_id asc;
$$;

revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from public;
revoke all on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) from anon, authenticated;
grant execute on function public.claim_due_toss_subscription_charges(timestamptz, integer, integer) to service_role;

create or replace function public.cancel_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = private, public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id()
  for update;

  if not found then
    raise exception 'Gym not found';
  end if;

  if v_gym.subscription_status = 'canceled' then
    return jsonb_build_object(
      'ok', true,
      'already_canceled', true,
      'current_period_end', v_gym.current_period_end
    );
  end if;

  if v_gym.subscription_status not in ('active', 'past_due') then
    raise exception 'NOTHING_TO_CANCEL';
  end if;

  perform set_config('app.allow_billing_update', '1', true);

  update public.gyms
  set
    subscription_status = 'canceled',
    auto_renew = false,
    updated_at = now()
  where id = v_gym.id;

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
    v_gym.id,
    'pro',
    'canceled',
    coalesce(v_gym.billing_provider, 'toss'),
    null,
    0,
    now(),
    v_gym.current_period_end,
    jsonb_build_object('canceled_by', auth.uid(), 'reason', 'user_cancel')
  );

  return jsonb_build_object(
    'ok', true,
    'already_canceled', false,
    'current_period_end', v_gym.current_period_end
  );
end;
$$;

revoke all on function public.cancel_gym_subscription() from public;
revoke all on function public.cancel_gym_subscription() from anon;
grant execute on function public.cancel_gym_subscription() to authenticated;

create or replace function public.resume_gym_subscription()
returns jsonb
language plpgsql
security definer
set search_path = private, public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id()
  for update;

  if not found then
    raise exception 'Gym not found';
  end if;

  if v_gym.subscription_status <> 'canceled'
     or v_gym.current_period_end is null
     or v_gym.current_period_end <= now() then
    raise exception 'NOTHING_TO_RESUME';
  end if;

  if v_gym.billing_customer_id is null
     or not private.gym_has_billing_credential(v_gym.id) then
    raise exception 'BILLING_KEY_NOT_FOUND';
  end if;

  perform set_config('app.allow_billing_update', '1', true);

  update public.gyms
  set
    plan_code = 'pro',
    member_limit = -1,
    subscription_status = 'active',
    auto_renew = true,
    updated_at = now()
  where id = v_gym.id;

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
    v_gym.id,
    'pro',
    'active',
    coalesce(v_gym.billing_provider, 'toss'),
    null,
    0,
    now(),
    v_gym.current_period_end,
    jsonb_build_object('resumed_by', auth.uid(), 'reason', 'user_resume')
  );

  return jsonb_build_object(
    'ok', true,
    'current_period_end', v_gym.current_period_end
  );
end;
$$;

revoke all on function public.resume_gym_subscription() from public;
revoke all on function public.resume_gym_subscription() from anon;
grant execute on function public.resume_gym_subscription() to authenticated;

create or replace function public.get_billing_summary()
returns jsonb
language plpgsql
stable
security definer
set search_path = private, public
as $$
declare
  v_gym public.gyms%rowtype;
  v_count integer;
  v_limit integer;
  v_pro boolean;
  v_has_credential boolean;
begin
  select * into v_gym
  from public.gyms
  where id = public.current_gym_id();

  if not found then
    raise exception 'Gym not found';
  end if;

  select count(*) into v_count
  from public.members
  where gym_id = v_gym.id;

  v_pro := public.gym_has_pro_access(v_gym);
  v_limit := public.gym_effective_member_limit(v_gym.id);
  v_has_credential := private.gym_has_billing_credential(v_gym.id);

  return jsonb_build_object(
    'gym_id', v_gym.id,
    'plan_code', v_gym.plan_code,
    'subscription_status', v_gym.subscription_status,
    'trial_ends_at', v_gym.trial_ends_at,
    'current_period_end', v_gym.current_period_end,
    'member_limit', v_limit,
    'member_count', v_count,
    'has_pro', v_pro,
    'can_add_member', (v_limit = -1 or v_count < v_limit),
    'can_cancel', (v_gym.subscription_status in ('active', 'past_due')),
    'can_resume', (
      v_gym.subscription_status = 'canceled'
      and v_gym.current_period_end is not null
      and v_gym.current_period_end > now()
      and v_gym.billing_customer_id is not null
      and v_has_credential
    ),
    'auto_renew', coalesce(v_gym.auto_renew, false),
    'billing_provider', v_gym.billing_provider
  );
end;
$$;

revoke all on function public.get_billing_summary() from public;
revoke all on function public.get_billing_summary() from anon;
grant execute on function public.get_billing_summary() to authenticated;

-- =============================================================================
-- requires Founder approval before applying to production
--
-- Safe backfill and cleanup of payment credentials already stored where
-- owner roles can read them. Copy first, then remove only values that were
-- copied, and sanitize saved provider payloads.
--
-- Idempotent. Does not change plan status, charge amounts, period dates,
-- or the renewal schedule. Does not delete gyms, members, or payment rows.
--
-- A repeated run does not replace a value already stored privately.
-- A previous copy is cleared only when it matches the private value.
-- =============================================================================

create or replace function private.backfill_billing_credentials()
returns void
language plpgsql
security definer
set search_path = private, public
as $payment_credential_backfill$
begin
  perform set_config('app.allow_billing_update', '1', true);

  insert into private.billing_credentials (
    gym_id,
    provider,
    billing_key
  )
  select
    g.id,
    'toss',
    btrim(g.billing_subscription_id)
  from public.gyms g
  where g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and length(btrim(g.billing_subscription_id)) > 0
  on conflict (gym_id, provider) do nothing;

  insert into private.billing_credentials (
    gym_id,
    provider,
    billing_key
  )
  select distinct on (pa.gym_id)
    pa.gym_id,
    'toss',
    btrim(pa.billing_key_ref)
  from public.payment_attempts pa
  where pa.provider = 'toss'
    and pa.billing_key_ref is not null
    and length(btrim(pa.billing_key_ref)) > 0
    and not exists (
      select 1
      from private.billing_credentials c
      where c.gym_id = pa.gym_id
        and c.provider = 'toss'
    )
  order by pa.gym_id, pa.updated_at desc nulls last, pa.created_at desc
  on conflict (gym_id, provider) do nothing;

  update public.subscriptions s
  set provider_ref = null
  where s.provider = 'toss'
    and s.provider_ref is not null
    and exists (
      select 1
      from private.billing_credentials c
      where c.gym_id = s.gym_id
        and c.provider = 'toss'
        and c.billing_key = s.provider_ref
    );

  update public.gyms g
  set billing_subscription_id = null
  where g.billing_provider = 'toss'
    and g.billing_subscription_id is not null
    and exists (
      select 1
      from private.billing_credentials c
      where c.gym_id = g.id
        and c.provider = 'toss'
        and c.billing_key = btrim(g.billing_subscription_id)
    );

  update public.payment_attempts pa
  set billing_key_ref = null
  where pa.provider = 'toss'
    and pa.billing_key_ref is not null
    and exists (
      select 1
      from private.billing_credentials c
      where c.gym_id = pa.gym_id
        and c.provider = 'toss'
        and c.billing_key = btrim(pa.billing_key_ref)
    );

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
end
$payment_credential_backfill$;

revoke all on function private.backfill_billing_credentials() from public;
revoke all on function private.backfill_billing_credentials() from anon, authenticated;

-- Applying this file runs the backfill. Stop before this call only when
-- exercising the schema on a disposable database.
select private.backfill_billing_credentials();
