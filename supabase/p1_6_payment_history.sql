-- P1-6 minimal payment history
-- Shows current gym payment history from payment_attempts only.

create or replace function public.get_payment_history()
returns table (
  payment_attempt_id uuid,
  provider text,
  payment_type text,
  amount_krw integer,
  display_status text,
  target_period_start timestamptz,
  target_period_end timestamptz,
  created_at timestamptz,
  activated_at timestamptz,
  recovery_status text
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_gym_id uuid;
begin
  if auth.uid() is null then
    raise exception 'AUTH_REQUIRED';
  end if;

  v_gym_id := public.current_gym_id();

  if v_gym_id is null then
    raise exception 'GYM_NOT_FOUND';
  end if;

  return query
  select
    pa.id as payment_attempt_id,
    pa.provider,
    pa.payment_type,
    pa.amount_krw,
    case
      when pa.status = 'completed'
           and pa.activation_status = 'succeeded'
        then 'success'
      when pa.status = 'charge_failed'
           or pa.recovery_status = 'failed'
        then 'failed'
      else 'processing'
    end as display_status,
    pa.target_period_start,
    pa.target_period_end,
    pa.created_at,
    pa.activated_at,
    pa.recovery_status
  from public.payment_attempts pa
  where pa.gym_id = v_gym_id
  order by
    coalesce(pa.activated_at, pa.updated_at, pa.created_at) desc,
    pa.created_at desc;
end;
$$;

revoke all on function public.get_payment_history() from public;
revoke all on function public.get_payment_history() from anon;
grant execute on function public.get_payment_history() to authenticated;
