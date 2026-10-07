-- =============================================================================
-- Atomic member JSON restore
-- Run after billing.sql so gym_effective_member_limit() is available.
-- =============================================================================

create or replace function public.restore_gym_members_from_json(p_members jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_gym_id uuid;
  v_limit integer;
  v_member_count integer;
  v_restored_members integer := 0;
  v_restored_attendance integer := 0;
  v_member jsonb;
  v_attendance jsonb;
  v_member_id uuid;
  v_start_date date;
  v_expire_date date;
  v_pt_total integer;
  v_pt_remaining integer;
  v_total_visits integer;
  v_last_visit date;
  v_attendance_date date;
  v_pt_used integer;
  v_created_at timestamptz;
begin
  if v_user_id is null then
    raise exception 'UNAUTHORIZED';
  end if;

  if p_members is null or jsonb_typeof(p_members) <> 'array' then
    raise exception 'INVALID_RESTORE_PAYLOAD';
  end if;

  v_gym_id := public.current_gym_id();

  if v_gym_id is null then
    raise exception 'GYM_NOT_FOUND';
  end if;

  perform 1
  from public.gyms
  where id = v_gym_id
  for update;

  v_member_count := jsonb_array_length(p_members);
  v_limit := public.gym_effective_member_limit(v_gym_id);

  if v_limit <> -1 and v_member_count > v_limit then
    raise exception 'MEMBER_LIMIT_REACHED:%', v_limit
      using errcode = 'P0001';
  end if;

  delete from public.members
  where gym_id = v_gym_id;

  for v_member in
    select value
    from jsonb_array_elements(p_members)
  loop
    if jsonb_typeof(v_member) <> 'object' then
      raise exception 'INVALID_MEMBER_PAYLOAD';
    end if;

    v_start_date := coalesce(
      nullif(v_member->>'startDate', '')::date,
      current_date
    );

    v_expire_date := coalesce(
      nullif(v_member->>'expireDate', '')::date,
      v_start_date + 30
    );

    v_pt_total := greatest(
      coalesce(nullif(v_member->>'ptTotal', '')::integer, 0),
      0
    );

    v_pt_remaining := greatest(
      coalesce(nullif(v_member->>'ptRemaining', '')::integer, 0),
      0
    );

    v_total_visits := greatest(
      coalesce(nullif(v_member->>'totalVisits', '')::integer, 0),
      0
    );

    v_last_visit := nullif(v_member->>'lastVisit', '')::date;

    insert into public.members (
      gym_id,
      name,
      phone,
      address,
      start_date,
      expire_date,
      pt_total,
      pt_remaining,
      memo,
      last_visit,
      total_visits
    )
    values (
      v_gym_id,
      coalesce(v_member->>'name', ''),
      coalesce(v_member->>'phone', ''),
      coalesce(v_member->>'address', ''),
      v_start_date,
      v_expire_date,
      v_pt_total,
      v_pt_remaining,
      coalesce(v_member->>'memo', ''),
      v_last_visit,
      v_total_visits
    )
    returning id into v_member_id;

    v_restored_members := v_restored_members + 1;

    if jsonb_typeof(v_member->'attendance') = 'array' then
      for v_attendance in
        select value
        from jsonb_array_elements(v_member->'attendance')
      loop
        if jsonb_typeof(v_attendance) <> 'object' then
          raise exception 'INVALID_ATTENDANCE_PAYLOAD';
        end if;

        v_attendance_date := coalesce(
          nullif(v_attendance->>'visitDate', '')::date,
          nullif(
            left(coalesce(v_attendance->>'date', ''), 10),
            ''
          )::date
        );

        if v_attendance_date is null then
          continue;
        end if;

        if jsonb_typeof(v_attendance->'ptDeducted') = 'boolean'
           and coalesce(
             (v_attendance->>'ptDeducted')::boolean,
             true
           ) = false then
          v_pt_used := 0;
        else
          if coalesce(v_attendance->>'ptUsed', '') ~ '^[0-9]+$' then
            v_pt_used := (v_attendance->>'ptUsed')::integer;
          else
            v_pt_used := 1;
          end if;

          if v_pt_used <= 0 then
            v_pt_used := 1;
          end if;
        end if;

        v_created_at := coalesce(
          nullif(v_attendance->>'date', '')::timestamptz,
          now()
        );

        insert into public.attendance (
          member_id,
          gym_id,
          attendance_date,
          pt_used,
          created_at
        )
        values (
          v_member_id,
          v_gym_id,
          v_attendance_date,
          v_pt_used,
          v_created_at
        );

        v_restored_attendance := v_restored_attendance + 1;
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'gym_id', v_gym_id,
    'restored_members', v_restored_members,
    'restored_attendance', v_restored_attendance
  );
end;
$$;

revoke all on function public.restore_gym_members_from_json(jsonb) from public;
revoke all on function public.restore_gym_members_from_json(jsonb) from anon;
grant execute on function public.restore_gym_members_from_json(jsonb) to authenticated;