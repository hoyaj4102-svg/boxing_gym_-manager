-- =============================================================================
-- P1-20 billing consent records (NOT APPLIED TO PRODUCTION)
-- =============================================================================
--
-- Draft legal-readiness schema for pre-payment, trial-to-paid, and
-- price-increase consent. Do not apply this file to the production database
-- without a separate Founder approval.
--
-- This file does not change billing credential storage, payment-reference
-- redaction, get_billing_summary(), gym_has_pro_access(), or charge mode.
-- It does not insert gyms, schedules, or consent rows.
-- =============================================================================

create table if not exists public.billing_price_schedules (
  id uuid primary key default gen_random_uuid(),
  plan_code text not null check (plan_code in ('pro')),
  amount_before_krw integer not null check (amount_before_krw >= 0),
  amount_after_krw integer not null check (amount_after_krw > amount_before_krw),
  effective_at timestamptz not null,
  status text not null default 'scheduled' check (status in ('scheduled', 'canceled')),
  created_at timestamptz not null default now()
);

create table if not exists public.billing_consents (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  user_id uuid not null,
  consent_type text not null check (consent_type in ('pre_payment', 'trial_to_paid', 'price_increase')),
  decision text not null check (decision in ('grant', 'decline')),
  policy_version text not null,
  amount_before_krw integer,
  amount_after_krw integer,
  conversion_at timestamptz,
  schedule_id uuid references public.billing_price_schedules (id),
  payment_method text not null,
  cancellation_method text not null,
  notice_channel text not null default 'in_app' check (notice_channel in ('in_app')),
  created_at timestamptz not null default now(),
  seq bigint generated always as identity,
  check (
    (consent_type = 'price_increase' and schedule_id is not null)
    or (consent_type <> 'price_increase' and schedule_id is null)
  )
);

create index if not exists billing_consents_gym_type_created_idx
  on public.billing_consents (gym_id, consent_type, created_at desc);

create index if not exists billing_price_schedules_effective_idx
  on public.billing_price_schedules (plan_code, status, effective_at);

alter table public.billing_price_schedules enable row level security;
alter table public.billing_consents enable row level security;

revoke all on table public.billing_price_schedules from public, anon, authenticated;
grant select, insert, update on table public.billing_price_schedules to service_role;

revoke all on table public.billing_consents from public, anon, authenticated;
grant select on table public.billing_consents to authenticated;
grant select, insert on table public.billing_consents to service_role;

drop policy if exists "Gym can view own billing consents" on public.billing_consents;
create policy "Gym can view own billing consents"
on public.billing_consents
for select
to authenticated
using (gym_id = public.current_gym_id());

create or replace function public.billing_consent_in_window(
  p_consented_at timestamptz,
  p_conversion_at timestamptz
)
returns boolean
language sql
immutable
as $$
  select p_consented_at is not null
    and p_conversion_at is not null
    and p_consented_at >= p_conversion_at - interval '30 days'
    and p_consented_at < p_conversion_at;
$$;

revoke all on function public.billing_consent_in_window(timestamptz, timestamptz) from public;
revoke all on function public.billing_consent_in_window(timestamptz, timestamptz) from anon;
grant execute on function public.billing_consent_in_window(timestamptz, timestamptz) to authenticated, service_role;

create or replace function public.billing_latest_decision(
  p_gym_id uuid,
  p_consent_type text,
  p_conversion_at timestamptz,
  p_schedule_id uuid
)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case c.decision
    when 'grant' then 'granted'
    when 'decline' then 'declined'
    else 'missing'
  end
  from public.billing_consents c
  where c.gym_id = p_gym_id
    and c.consent_type = p_consent_type
    and c.conversion_at is not distinct from p_conversion_at
    and c.schedule_id is not distinct from p_schedule_id
  order by c.seq desc
  limit 1;
$$;

revoke all on function public.billing_latest_decision(uuid, text, timestamptz, uuid) from public;
revoke all on function public.billing_latest_decision(uuid, text, timestamptz, uuid) from anon, authenticated;
grant execute on function public.billing_latest_decision(uuid, text, timestamptz, uuid) to service_role;

create or replace function public.billing_subject_granted(
  p_gym_id uuid,
  p_consent_type text,
  p_conversion_at timestamptz,
  p_schedule_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select coalesce((
    select c.decision = 'grant'
      and (
        p_conversion_at is null
        or public.billing_consent_in_window(c.created_at, p_conversion_at)
      )
    from public.billing_consents c
    where c.gym_id = p_gym_id
      and c.consent_type = p_consent_type
      and c.conversion_at is not distinct from p_conversion_at
      and c.schedule_id is not distinct from p_schedule_id
    order by c.seq desc
    limit 1
  ), false);
$$;

revoke all on function public.billing_subject_granted(uuid, text, timestamptz, uuid) from public;
revoke all on function public.billing_subject_granted(uuid, text, timestamptz, uuid) from anon, authenticated;
grant execute on function public.billing_subject_granted(uuid, text, timestamptz, uuid) to service_role;

create or replace function public.record_billing_consent(
  p_consent_type text,
  p_decision text,
  p_schedule_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_gym public.gyms%rowtype;
  v_schedule public.billing_price_schedules%rowtype;
  v_conversion timestamptz;
  v_before integer;
  v_after integer;
  v_id uuid;
  v_cancellation constant text := '요금제 화면의 해지 버튼으로 해지합니다. 해지 후 다음 결제일부터 자동결제가 중단되고, 이미 결제한 이용 종료일까지 Pro를 사용할 수 있습니다.';
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED');
  end if;

  if p_decision not in ('grant', 'decline') then
    return jsonb_build_object('ok', false, 'code', 'INVALID_DECISION');
  end if;

  select * into v_gym
  from public.gyms
  where id = public.current_gym_id();

  if not found then
    return jsonb_build_object('ok', false, 'code', 'GYM_NOT_FOUND');
  end if;

  if p_consent_type = 'pre_payment' then
    if p_schedule_id is not null then
      return jsonb_build_object('ok', false, 'code', 'SCHEDULE_NOT_ALLOWED');
    end if;
    v_before := null;
    v_after := 10000;
    v_conversion := null;
  elsif p_consent_type = 'trial_to_paid' then
    if p_schedule_id is not null then
      return jsonb_build_object('ok', false, 'code', 'SCHEDULE_NOT_ALLOWED');
    end if;
    if v_gym.subscription_status is distinct from 'trialing' or v_gym.trial_ends_at is null then
      return jsonb_build_object('ok', false, 'code', 'NOT_TRIALING');
    end if;
    if not public.billing_consent_in_window(now(), v_gym.trial_ends_at) then
      if now() >= v_gym.trial_ends_at then
        return jsonb_build_object('ok', false, 'code', 'WINDOW_CLOSED');
      end if;
      return jsonb_build_object('ok', false, 'code', 'WINDOW_NOT_OPEN');
    end if;
    v_before := 0;
    v_after := 10000;
    v_conversion := v_gym.trial_ends_at;
  elsif p_consent_type = 'price_increase' then
    if p_schedule_id is null then
      return jsonb_build_object('ok', false, 'code', 'SCHEDULE_REQUIRED');
    end if;
    select * into v_schedule
    from public.billing_price_schedules
    where id = p_schedule_id
      and plan_code = 'pro'
      and status = 'scheduled';
    if not found then
      return jsonb_build_object('ok', false, 'code', 'SCHEDULE_NOT_FOUND');
    end if;
    if not public.billing_consent_in_window(now(), v_schedule.effective_at) then
      if now() >= v_schedule.effective_at then
        return jsonb_build_object('ok', false, 'code', 'WINDOW_CLOSED');
      end if;
      return jsonb_build_object('ok', false, 'code', 'WINDOW_NOT_OPEN');
    end if;
    v_before := v_schedule.amount_before_krw;
    v_after := v_schedule.amount_after_krw;
    v_conversion := v_schedule.effective_at;
  else
    return jsonb_build_object('ok', false, 'code', 'INVALID_CONSENT_TYPE');
  end if;

  insert into public.billing_consents (
    gym_id,
    user_id,
    consent_type,
    decision,
    policy_version,
    amount_before_krw,
    amount_after_krw,
    conversion_at,
    schedule_id,
    payment_method,
    cancellation_method,
    notice_channel
  ) values (
    v_gym.id,
    v_user_id,
    p_consent_type,
    p_decision,
    'draft-2026-11-12',
    v_before,
    v_after,
    v_conversion,
    case when p_consent_type = 'price_increase' then p_schedule_id else null end,
    'toss_card_auto_pay',
    v_cancellation,
    'in_app'
  )
  returning id into v_id;

  return jsonb_build_object(
    'ok', true,
    'code', 'RECORDED',
    'consent_id', v_id,
    'decision', p_decision,
    'consent_type', p_consent_type
  );
end;
$$;

revoke all on function public.record_billing_consent(text, text, uuid) from public;
revoke all on function public.record_billing_consent(text, text, uuid) from anon;
grant execute on function public.record_billing_consent(text, text, uuid) to authenticated;

create or replace function public.get_billing_readiness()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
  v_cancellation constant text := '요금제 화면의 해지 버튼으로 해지합니다. 해지 후 다음 결제일부터 자동결제가 중단되고, 이미 결제한 이용 종료일까지 Pro를 사용할 수 있습니다.';
  v_fresh boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED');
  end if;

  select * into v_gym
  from public.gyms
  where id = public.current_gym_id();

  if not found then
    return jsonb_build_object('ok', false, 'code', 'GYM_NOT_FOUND');
  end if;

  select c.decision = 'grant'
    and c.policy_version = 'draft-2026-11-12'
    and c.amount_after_krw = 10000
    and c.created_at >= now() - interval '6 hours'
  into v_fresh
  from public.billing_consents c
  where c.gym_id = v_gym.id
    and c.consent_type = 'pre_payment'
  order by c.seq desc
  limit 1;

  return jsonb_build_object(
    'ok', true,
    'policy_version', 'draft-2026-11-12',
    'catalog_amount_krw', 10000,
    'currency', 'KRW',
    'billing_cycle', 'monthly',
    'auto_renew_on_subscribe', true,
    'payment_method', 'toss_card_auto_pay',
    'payment_method_label', '등록하는 카드로 매월 자동결제',
    'cancellation_method', v_cancellation,
    'draft', true,
    'trial', jsonb_build_object(
      'subscription_status', v_gym.subscription_status,
      'trial_ends_at', v_gym.trial_ends_at,
      'window_open', public.billing_consent_in_window(now(), v_gym.trial_ends_at),
      'consent_status', coalesce(
        public.billing_latest_decision(v_gym.id, 'trial_to_paid', v_gym.trial_ends_at, null),
        'missing'
      ),
      'consent_required_for_conversion', (
        v_gym.subscription_status = 'trialing'
        and public.billing_consent_in_window(now(), v_gym.trial_ends_at)
      )
    ),
    'pre_payment', jsonb_build_object(
      'latest_status', coalesce(
        public.billing_latest_decision(v_gym.id, 'pre_payment', null, null),
        'missing'
      ),
      'fresh_grant', coalesce(v_fresh, false)
    ),
    'price_schedules', coalesce((
      select jsonb_agg(jsonb_build_object(
        'schedule_id', s.id,
        'effective_at', s.effective_at,
        'amount_before_krw', s.amount_before_krw,
        'amount_after_krw', s.amount_after_krw,
        'window_open', public.billing_consent_in_window(now(), s.effective_at),
        'consent_status', coalesce(
          public.billing_latest_decision(v_gym.id, 'price_increase', s.effective_at, s.id),
          'missing'
        )
      ) order by s.effective_at)
      from public.billing_price_schedules s
      where s.plan_code = 'pro'
        and s.status = 'scheduled'
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_billing_readiness() from public;
revoke all on function public.get_billing_readiness() from anon;
grant execute on function public.get_billing_readiness() to authenticated;

create or replace function public.billing_charge_consent_gate(
  p_gym_id uuid,
  p_amount_krw integer,
  p_purpose text
)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym public.gyms%rowtype;
begin
  if p_purpose not in ('initial', 'renewal') then
    return jsonb_build_object('allowed', false, 'code', 'INVALID_PURPOSE');
  end if;

  select * into v_gym
  from public.gyms
  where id = p_gym_id;

  if not found then
    return jsonb_build_object('allowed', false, 'code', 'GYM_NOT_FOUND');
  end if;

  if p_amount_krw is distinct from 10000 then
    if not exists (
      select 1
      from public.billing_price_schedules s
      where s.plan_code = 'pro'
        and s.status = 'scheduled'
        and s.amount_after_krw = p_amount_krw
        and s.effective_at <= now()
        and public.billing_subject_granted(
          p_gym_id,
          'price_increase',
          s.effective_at,
          s.id
        )
    ) then
      return jsonb_build_object('allowed', false, 'code', 'PRICE_NOT_AUTHORIZED');
    end if;
  end if;

  if p_purpose = 'renewal' then
    return jsonb_build_object('allowed', true, 'code', 'OK');
  end if;

  if not exists (
    select 1
    from (
      select c.decision, c.policy_version, c.amount_after_krw, c.created_at
      from public.billing_consents c
      where c.gym_id = p_gym_id
        and c.consent_type = 'pre_payment'
      order by c.seq desc
      limit 1
    ) latest
    where latest.decision = 'grant'
      and latest.policy_version = 'draft-2026-11-12'
      and latest.amount_after_krw = 10000
      and latest.created_at >= now() - interval '6 hours'
  ) then
    return jsonb_build_object('allowed', false, 'code', 'PRE_PAYMENT_CONSENT_REQUIRED');
  end if;

  if v_gym.subscription_status = 'trialing'
     and public.billing_consent_in_window(now(), v_gym.trial_ends_at)
     and not public.billing_subject_granted(
       p_gym_id,
       'trial_to_paid',
       v_gym.trial_ends_at,
       null
     )
  then
    return jsonb_build_object('allowed', false, 'code', 'TRIAL_CONSENT_REQUIRED');
  end if;

  return jsonb_build_object('allowed', true, 'code', 'OK');
end;
$$;

revoke all on function public.billing_charge_consent_gate(uuid, integer, text) from public;
revoke all on function public.billing_charge_consent_gate(uuid, integer, text) from anon, authenticated;
grant execute on function public.billing_charge_consent_gate(uuid, integer, text) to service_role;
