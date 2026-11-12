-- =============================================================================
-- P1-18 test-mode refund and payment-failure records
-- =============================================================================
--
-- NOT APPLIED TO PRODUCTION.
-- Do not run this file in the production SQL editor without a separate approval.
-- It does not change billing credential storage, redaction, charge mode, or
-- gym_has_pro_access(). It does not schedule a job and it does not call Toss.
-- =============================================================================

create table if not exists public.billing_payment_failures (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  payment_attempt_id uuid not null references public.payment_attempts (id) on delete cascade,
  failed_at timestamptz not null,
  first_failed_at timestamptz not null,
  failure_count integer not null check (failure_count >= 1),
  grace_until timestamptz not null,
  next_retry_at timestamptz,
  state text not null check (state in ('past_due', 'grace_expired')),
  card_reregistration_required boolean not null default true,
  error_code text,
  retry_dispatched_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.billing_notifications (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  kind text not null,
  title text not null,
  body text not null,
  href text,
  email_status text not null default 'disabled' check (email_status = 'disabled'),
  sms_status text not null default 'disabled' check (sms_status = 'disabled'),
  read_at timestamptz,
  created_at timestamptz not null default now()
);

create table if not exists public.billing_refund_requests (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  user_id uuid not null,
  payment_attempt_id uuid not null references public.payment_attempts (id) on delete cascade,
  reason text not null,
  amount_krw integer not null,
  requested_amount_krw integer not null,
  normally_used boolean,
  decision_code text not null,
  allowed boolean not null,
  status text not null default 'recorded',
  provider_called boolean not null default false,
  created_at timestamptz not null default now()
);

alter table public.billing_payment_failures enable row level security;
alter table public.billing_notifications enable row level security;
alter table public.billing_refund_requests enable row level security;

revoke all on table public.billing_payment_failures from public, anon, authenticated;
revoke all on table public.billing_notifications from public, anon, authenticated;
revoke all on table public.billing_refund_requests from public, anon, authenticated;
grant select on table public.billing_notifications to authenticated;
grant select on table public.billing_refund_requests to authenticated;
grant select, insert, update on table public.billing_payment_failures to service_role;
grant select, insert, update on table public.billing_notifications to service_role;
grant select, insert, update on table public.billing_refund_requests to service_role;

drop policy if exists "Gym can view own billing notifications" on public.billing_notifications;
create policy "Gym can view own billing notifications"
on public.billing_notifications for select to authenticated
using (gym_id = public.current_gym_id());

drop policy if exists "Gym can view own refund requests" on public.billing_refund_requests;
create policy "Gym can view own refund requests"
on public.billing_refund_requests for select to authenticated
using (gym_id = public.current_gym_id());

create or replace function public.evaluate_draft_refund(
  p_paid_at timestamptz,
  p_now timestamptz,
  p_amount_krw integer,
  p_requested_amount_krw integer,
  p_reason text,
  p_normally_used boolean
)
returns jsonb
language plpgsql
immutable
as $$
begin
  if p_amount_krw is null or p_amount_krw <= 0 then
    return jsonb_build_object('allowed', false, 'code', 'INVALID_AMOUNT', 'refund_amount_krw', 0);
  end if;
  if p_requested_amount_krw is null
     or p_requested_amount_krw <= 0
     or p_requested_amount_krw > p_amount_krw then
    return jsonb_build_object('allowed', false, 'code', 'INVALID_REQUESTED_AMOUNT', 'refund_amount_krw', 0);
  end if;
  if p_requested_amount_krw <> p_amount_krw then
    return jsonb_build_object('allowed', false, 'code', 'PARTIAL_REFUND_NOT_IN_DRAFT_POLICY', 'refund_amount_krw', 0);
  end if;
  if p_reason in ('duplicate_charge', 'system_error') then
    return jsonb_build_object('allowed', true, 'code', 'FULL_REFUND_DUPLICATE_OR_SYSTEM_ERROR', 'refund_amount_krw', p_amount_krw);
  end if;
  if p_reason is distinct from 'customer_request' then
    return jsonb_build_object('allowed', false, 'code', 'UNKNOWN_REASON', 'refund_amount_krw', 0);
  end if;
  if p_paid_at is null or p_now is null or p_now < p_paid_at then
    return jsonb_build_object('allowed', false, 'code', 'INVALID_TIME', 'refund_amount_krw', 0);
  end if;
  if p_now > p_paid_at + interval '7 days' then
    return jsonb_build_object('allowed', false, 'code', 'REFUND_WINDOW_EXPIRED', 'refund_amount_krw', 0);
  end if;
  if p_normally_used is true then
    return jsonb_build_object('allowed', false, 'code', 'NORMAL_USE_LIMIT', 'refund_amount_krw', 0);
  end if;
  if p_normally_used is distinct from false then
    return jsonb_build_object('allowed', false, 'code', 'NORMAL_USE_UNCONFIRMED', 'refund_amount_krw', 0);
  end if;
  return jsonb_build_object('allowed', true, 'code', 'FULL_REFUND_WITHIN_7_DAYS', 'refund_amount_krw', p_amount_krw);
end;
$$;

revoke all on function public.evaluate_draft_refund(timestamptz, timestamptz, integer, integer, text, boolean) from public;
revoke all on function public.evaluate_draft_refund(timestamptz, timestamptz, integer, integer, text, boolean) from anon;
grant execute on function public.evaluate_draft_refund(timestamptz, timestamptz, integer, integer, text, boolean) to authenticated, service_role;

create or replace function public.record_payment_failure(
  p_gym_id uuid,
  p_payment_attempt_id uuid,
  p_failed_at timestamptz,
  p_error_code text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
  v_first timestamptz;
  v_grace timestamptz;
  v_next timestamptz;
  v_state text;
  v_id uuid;
begin
  select coalesce(max(failure_count), 0) + 1, min(failed_at)
  into v_count, v_first
  from public.billing_payment_failures
  where gym_id = p_gym_id
    and state = 'past_due';

  v_first := coalesce(v_first, p_failed_at);
  v_grace := v_first + interval '7 days';
  v_next := case v_count
    when 1 then v_first + interval '24 hours'
    when 2 then v_first + interval '72 hours'
    when 3 then v_first + interval '120 hours'
    else null
  end;
  if v_next is not null and v_next > v_grace then
    v_next := null;
  end if;
  v_state := case
    when p_failed_at >= v_grace or v_count >= 4 then 'grace_expired'
    else 'past_due'
  end;

  insert into public.billing_payment_failures (
    gym_id, payment_attempt_id, failed_at, first_failed_at, failure_count,
    grace_until, next_retry_at, state, card_reregistration_required, error_code
  ) values (
    p_gym_id, p_payment_attempt_id, p_failed_at, v_first, v_count,
    v_grace, v_next, v_state, true, p_error_code
  )
  returning id into v_id;

  insert into public.billing_notifications (
    gym_id, kind, title, body, email_status, sms_status
  ) values (
    p_gym_id,
    'payment_failed',
    '결제에 실패했습니다',
    '카드를 다시 등록해 주세요. 이메일과 문자는 보내지 않습니다.',
    'disabled',
    'disabled'
  );

  return jsonb_build_object(
    'ok', true,
    'failure_id', v_id,
    'state', v_state,
    'failure_count', v_count,
    'grace_until', v_grace,
    'next_retry_at', v_next,
    'email', 'disabled',
    'sms', 'disabled'
  );
end;
$$;

revoke all on function public.record_payment_failure(uuid, uuid, timestamptz, text) from public;
revoke all on function public.record_payment_failure(uuid, uuid, timestamptz, text) from anon, authenticated;
grant execute on function public.record_payment_failure(uuid, uuid, timestamptz, text) to service_role;

-- Payment keys used for cancel and receipt lookup come only from dedicated
-- columns. provider_response and checkout raw JSON are redacted and are not read.
create or replace function public.resolve_attempt_payment_key(p_attempt_id uuid)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(
    nullif(btrim(pa.payment_key), ''),
    (
      select nullif(btrim(cs.provider_session_id), '')
      from public.checkout_sessions cs
      where cs.gym_id = pa.gym_id
        and cs.order_id = pa.order_id
        and nullif(btrim(cs.provider_session_id), '') is not null
      order by cs.completed_at desc nulls last, cs.created_at desc
      limit 1
    ),
    (
      select nullif(btrim(s.provider_ref), '')
      from public.subscriptions s
      where s.gym_id = pa.gym_id
        and s.provider = 'toss'
        and nullif(btrim(s.provider_ref), '') is not null
        and nullif(btrim(pa.payment_key), '') is null
        and not exists (
          select 1
          from public.checkout_sessions cs
          where cs.gym_id = pa.gym_id
            and cs.order_id = pa.order_id
            and nullif(btrim(cs.provider_session_id), '') is not null
        )
        and (
          select count(*)
          from public.subscriptions s2
          where s2.gym_id = pa.gym_id
            and s2.provider = 'toss'
            and nullif(btrim(s2.provider_ref), '') is not null
        ) = 1
      limit 1
    )
  )
  from public.payment_attempts pa
  where pa.id = p_attempt_id;
$$;

revoke all on function public.resolve_attempt_payment_key(uuid) from public;
revoke all on function public.resolve_attempt_payment_key(uuid) from anon, authenticated;
grant execute on function public.resolve_attempt_payment_key(uuid) to service_role;

create or replace function public.create_billing_refund_request(
  p_payment_attempt_id uuid,
  p_reason text,
  p_requested_amount_krw integer,
  p_normally_used boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user uuid := auth.uid();
  v_attempt public.payment_attempts%rowtype;
  v_decision jsonb;
  v_id uuid;
begin
  if v_user is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED');
  end if;

  select * into v_attempt
  from public.payment_attempts
  where id = p_payment_attempt_id
    and gym_id = public.current_gym_id();

  if not found then
    return jsonb_build_object('ok', false, 'code', 'PAYMENT_NOT_FOUND');
  end if;
  if v_attempt.status is distinct from 'completed'
     or v_attempt.activation_status is distinct from 'succeeded' then
    return jsonb_build_object('ok', false, 'code', 'PAYMENT_NOT_REFUNDABLE');
  end if;

  v_decision := public.evaluate_draft_refund(
    coalesce(v_attempt.activated_at, v_attempt.created_at),
    now(),
    v_attempt.amount_krw,
    p_requested_amount_krw,
    p_reason,
    p_normally_used
  );

  insert into public.billing_refund_requests (
    gym_id, user_id, payment_attempt_id, reason, amount_krw,
    requested_amount_krw, normally_used, decision_code, allowed, status
  ) values (
    v_attempt.gym_id, v_user, v_attempt.id, p_reason, v_attempt.amount_krw,
    p_requested_amount_krw, p_normally_used, v_decision->>'code',
    (v_decision->>'allowed')::boolean, 'recorded'
  )
  returning id into v_id;

  insert into public.billing_notifications (
    gym_id, kind, title, body, email_status, sms_status
  ) values (
    v_attempt.gym_id,
    'refund_recorded',
    '환불 요청을 기록했습니다',
    '테스트 모드가 아니면 결제 취소 API를 호출하지 않습니다.',
    'disabled',
    'disabled'
  );

  return jsonb_build_object(
    'ok', true,
    'refund_request_id', v_id,
    'allowed', (v_decision->>'allowed')::boolean,
    'code', v_decision->>'code'
  );
end;
$$;

revoke all on function public.create_billing_refund_request(uuid, text, integer, boolean) from public;
revoke all on function public.create_billing_refund_request(uuid, text, integer, boolean) from anon;
grant execute on function public.create_billing_refund_request(uuid, text, integer, boolean) to authenticated;

create or replace function public.load_billing_refund_for_cancel(
  p_gym_id uuid,
  p_user_id uuid,
  p_refund_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.billing_refund_requests%rowtype;
  v_attempt public.payment_attempts%rowtype;
begin
  select * into v_request
  from public.billing_refund_requests
  where id = p_refund_request_id
    and gym_id = p_gym_id
    and user_id = p_user_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'REFUND_NOT_FOUND');
  end if;

  select * into v_attempt
  from public.payment_attempts
  where id = v_request.payment_attempt_id
    and gym_id = p_gym_id;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'PAYMENT_NOT_FOUND');
  end if;

  return jsonb_build_object(
    'ok', true,
    'paid_at', coalesce(v_attempt.activated_at, v_attempt.created_at),
    'amount_krw', v_request.amount_krw,
    'requested_amount_krw', v_request.requested_amount_krw,
    'reason', v_request.reason,
    'normally_used', v_request.normally_used,
    'payment_key', public.resolve_attempt_payment_key(v_attempt.id)
  );
end;
$$;

revoke all on function public.load_billing_refund_for_cancel(uuid, uuid, uuid) from public;
revoke all on function public.load_billing_refund_for_cancel(uuid, uuid, uuid) from anon, authenticated;
grant execute on function public.load_billing_refund_for_cancel(uuid, uuid, uuid) to service_role;

create or replace function public.record_billing_refund_result(
  p_refund_request_id uuid,
  p_status text,
  p_code text,
  p_provider_called boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if p_status = 'succeeded' and p_provider_called is distinct from true then
    return jsonb_build_object('ok', false, 'code', 'SUCCESS_WITHOUT_PROVIDER_CALL');
  end if;
  if p_status not in ('denied', 'blocked', 'succeeded', 'failed', 'uncertain') then
    return jsonb_build_object('ok', false, 'code', 'INVALID_STATUS');
  end if;

  update public.billing_refund_requests
  set
    status = p_status,
    decision_code = coalesce(p_code, decision_code),
    provider_called = coalesce(p_provider_called, false)
  where id = p_refund_request_id;

  return jsonb_build_object('ok', true, 'code', p_code);
end;
$$;

revoke all on function public.record_billing_refund_result(uuid, text, text, boolean) from public;
revoke all on function public.record_billing_refund_result(uuid, text, text, boolean) from anon, authenticated;
grant execute on function public.record_billing_refund_result(uuid, text, text, boolean) to service_role;

create or replace function public.claim_due_payment_failure_retries(
  p_now timestamptz,
  p_limit integer
)
returns table (
  failure_id uuid,
  gym_id uuid,
  payment_attempt_id uuid,
  order_id text,
  customer_key text,
  amount_krw integer
)
language plpgsql
security definer
set search_path = public
as $$
begin
  return query
  with due as (
    select f.id
    from public.billing_payment_failures f
    where f.state = 'past_due'
      and f.next_retry_at is not null
      and f.next_retry_at <= p_now
      and f.retry_dispatched_at is null
    order by f.next_retry_at, f.id
    limit greatest(least(coalesce(p_limit, 10), 20), 1)
    for update of f skip locked
  ),
  claimed as (
    update public.billing_payment_failures f
    set retry_dispatched_at = p_now
    from due
    where f.id = due.id
    returning f.id, f.gym_id, f.payment_attempt_id
  )
  select claimed.id, claimed.gym_id, claimed.payment_attempt_id,
    pa.order_id, pa.customer_key, pa.amount_krw
  from claimed
  join public.payment_attempts pa on pa.id = claimed.payment_attempt_id;
end;
$$;

revoke all on function public.claim_due_payment_failure_retries(timestamptz, integer) from public;
revoke all on function public.claim_due_payment_failure_retries(timestamptz, integer) from anon, authenticated;
grant execute on function public.claim_due_payment_failure_retries(timestamptz, integer) to service_role;

create or replace function public.get_billing_ops_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym_id uuid := public.current_gym_id();
begin
  if auth.uid() is null or v_gym_id is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED');
  end if;

  return jsonb_build_object(
    'ok', true,
    'failure', (
      select jsonb_build_object(
        'state', f.state,
        'failure_count', f.failure_count,
        'grace_until', f.grace_until,
        'next_retry_at', f.next_retry_at,
        'card_reregistration_required', f.card_reregistration_required
      )
      from public.billing_payment_failures f
      where f.gym_id = v_gym_id
      order by f.created_at desc
      limit 1
    ),
    'notifications', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', n.id,
        'kind', n.kind,
        'title', n.title,
        'body', n.body,
        'read_at', n.read_at,
        'created_at', n.created_at
      ) order by n.created_at desc)
      from public.billing_notifications n
      where n.gym_id = v_gym_id
    ), '[]'::jsonb),
    'refunds', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', rr.id,
        'payment_attempt_id', rr.payment_attempt_id,
        'decision_code', rr.decision_code,
        'allowed', rr.allowed,
        'status', rr.status,
        'provider_called', rr.provider_called,
        'amount_krw', rr.amount_krw,
        'created_at', rr.created_at
      ) order by rr.created_at desc)
      from public.billing_refund_requests rr
      where rr.gym_id = v_gym_id
    ), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.get_billing_ops_status() from public;
revoke all on function public.get_billing_ops_status() from anon;
grant execute on function public.get_billing_ops_status() to authenticated;

create or replace function public.mark_billing_notification_read(p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'code', 'AUTH_REQUIRED');
  end if;
  update public.billing_notifications
  set read_at = coalesce(read_at, now())
  where id = p_id
    and gym_id = public.current_gym_id();
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.mark_billing_notification_read(uuid) from public;
revoke all on function public.mark_billing_notification_read(uuid) from anon;
grant execute on function public.mark_billing_notification_read(uuid) to authenticated;
