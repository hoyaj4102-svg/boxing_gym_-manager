-- =============================================================================
-- Sweat Manager (복싱장 회원관리) SaaS Schema
-- Supabase Dashboard > SQL Editor 에서 전체 실행하세요.
-- =============================================================================

create extension if not exists pgcrypto;

-- -----------------------------------------------------------------------------
-- 1) Tables
-- -----------------------------------------------------------------------------

create table if not exists public.gyms (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  owner_name text not null default '',
  phone text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  gym_id uuid not null references public.gyms (id) on delete cascade,
  name text not null default '',
  created_at timestamptz not null default now()
);

create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  gym_id uuid not null references public.gyms (id) on delete cascade,
  name text not null,
  phone text not null default '',
  start_date date not null,
  expire_date date not null,
  pt_total integer not null default 0 check (pt_total >= 0),
  pt_remaining integer not null default 0 check (pt_remaining >= 0),
  memo text not null default '',
  last_visit date,
  total_visits integer not null default 0 check (total_visits >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.attendance (
  id uuid primary key default gen_random_uuid(),
  member_id uuid not null references public.members (id) on delete cascade,
  gym_id uuid not null references public.gyms (id) on delete cascade,
  attendance_date date not null default (timezone('utc', now()))::date,
  pt_used integer not null default 1 check (pt_used >= 0),
  created_at timestamptz not null default now()
);

-- -----------------------------------------------------------------------------
-- 2) Indexes
-- -----------------------------------------------------------------------------

create index if not exists profiles_gym_id_idx on public.profiles (gym_id);

create index if not exists members_gym_id_idx on public.members (gym_id);
create index if not exists members_gym_expire_date_idx on public.members (gym_id, expire_date);
create index if not exists members_gym_last_visit_idx on public.members (gym_id, last_visit);
create index if not exists members_gym_name_idx on public.members (gym_id, name);

create index if not exists attendance_gym_id_idx on public.attendance (gym_id);
create index if not exists attendance_member_id_idx on public.attendance (member_id);
create index if not exists attendance_gym_date_idx on public.attendance (gym_id, attendance_date);
create index if not exists attendance_member_date_idx on public.attendance (member_id, attendance_date);

-- -----------------------------------------------------------------------------
-- 3) updated_at auto refresh
-- -----------------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

drop trigger if exists members_set_updated_at on public.members;
create trigger members_set_updated_at
before update on public.members
for each row
execute function public.set_updated_at();

-- -----------------------------------------------------------------------------
-- 4) Helper: current user's gym_id
-- -----------------------------------------------------------------------------

create or replace function public.current_gym_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select gym_id
  from public.profiles
  where id = auth.uid()
$$;

revoke all on function public.current_gym_id() from public;
grant execute on function public.current_gym_id() to authenticated;

-- -----------------------------------------------------------------------------
-- 5) Signup: auth.users 생성 시 gym + profile 자동 생성
--    signUp options.data 에 gym_name / owner_name / phone 을 넣습니다.
-- -----------------------------------------------------------------------------

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym_id uuid;
  v_gym_name text;
  v_owner_name text;
  v_phone text;
begin
  v_gym_name := nullif(trim(coalesce(new.raw_user_meta_data->>'gym_name', '')), '');
  v_owner_name := coalesce(nullif(trim(coalesce(new.raw_user_meta_data->>'owner_name', '')), ''), split_part(new.email, '@', 1));
  v_phone := coalesce(new.raw_user_meta_data->>'phone', '');

  if v_gym_name is null then
    v_gym_name := coalesce(v_owner_name, 'My Gym') || ' Gym';
  end if;

  insert into public.gyms (name, owner_name, phone)
  values (v_gym_name, v_owner_name, v_phone)
  returning id into v_gym_id;

  insert into public.profiles (id, gym_id, name)
  values (new.id, v_gym_id, v_owner_name);

  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row
execute function public.handle_new_user();

-- -----------------------------------------------------------------------------
-- 6) Atomic attendance + PT deduction
-- -----------------------------------------------------------------------------

create or replace function public.record_attendance(
  p_member_id uuid,
  p_attendance_date date default current_date
)
returns public.attendance
language plpgsql
security definer
set search_path = public
as $$
declare
  v_gym_id uuid := public.current_gym_id();
  v_member public.members%rowtype;
  v_pt_used integer := 0;
  v_row public.attendance%rowtype;
  v_date date := coalesce(p_attendance_date, current_date);
begin
  if v_gym_id is null then
    raise exception 'Gym profile not found';
  end if;

  select * into v_member
  from public.members
  where id = p_member_id
    and gym_id = v_gym_id
  for update;

  if not found then
    raise exception 'Member not found';
  end if;

  if v_member.pt_remaining > 0 then
    v_pt_used := 1;
  end if;

  insert into public.attendance (member_id, gym_id, attendance_date, pt_used)
  values (p_member_id, v_gym_id, v_date, v_pt_used)
  returning * into v_row;

  update public.members
  set
    pt_remaining = greatest(pt_remaining - v_pt_used, 0),
    last_visit = v_date,
    total_visits = total_visits + 1,
    updated_at = now()
  where id = p_member_id
    and gym_id = v_gym_id;

  return v_row;
end;
$$;

revoke all on function public.record_attendance(uuid, date) from public;
grant execute on function public.record_attendance(uuid, date) to authenticated;

-- -----------------------------------------------------------------------------
-- 7) Row Level Security
-- -----------------------------------------------------------------------------

alter table public.gyms enable row level security;
alter table public.profiles enable row level security;
alter table public.members enable row level security;
alter table public.attendance enable row level security;

-- gyms
drop policy if exists "Gym owners can view own gym" on public.gyms;
create policy "Gym owners can view own gym"
on public.gyms
for select
to authenticated
using (id = public.current_gym_id());

drop policy if exists "Gym owners can update own gym" on public.gyms;
create policy "Gym owners can update own gym"
on public.gyms
for update
to authenticated
using (id = public.current_gym_id())
with check (id = public.current_gym_id());

-- profiles
drop policy if exists "Users can view own profile" on public.profiles;
create policy "Users can view own profile"
on public.profiles
for select
to authenticated
using (id = auth.uid());

drop policy if exists "Users can update own profile" on public.profiles;
create policy "Users can update own profile"
on public.profiles
for update
to authenticated
using (id = auth.uid())
with check (id = auth.uid() and gym_id = public.current_gym_id());

-- members
drop policy if exists "Gym can view own members" on public.members;
create policy "Gym can view own members"
on public.members
for select
to authenticated
using (gym_id = public.current_gym_id());

drop policy if exists "Gym can insert own members" on public.members;
create policy "Gym can insert own members"
on public.members
for insert
to authenticated
with check (gym_id = public.current_gym_id());

drop policy if exists "Gym can update own members" on public.members;
create policy "Gym can update own members"
on public.members
for update
to authenticated
using (gym_id = public.current_gym_id())
with check (gym_id = public.current_gym_id());

drop policy if exists "Gym can delete own members" on public.members;
create policy "Gym can delete own members"
on public.members
for delete
to authenticated
using (gym_id = public.current_gym_id());

-- attendance
drop policy if exists "Gym can view own attendance" on public.attendance;
create policy "Gym can view own attendance"
on public.attendance
for select
to authenticated
using (gym_id = public.current_gym_id());

drop policy if exists "Gym can insert own attendance" on public.attendance;
create policy "Gym can insert own attendance"
on public.attendance
for insert
to authenticated
with check (
  gym_id = public.current_gym_id()
  and exists (
    select 1
    from public.members m
    where m.id = member_id
      and m.gym_id = public.current_gym_id()
  )
);

drop policy if exists "Gym can update own attendance" on public.attendance;
create policy "Gym can update own attendance"
on public.attendance
for update
to authenticated
using (gym_id = public.current_gym_id())
with check (gym_id = public.current_gym_id());

drop policy if exists "Gym can delete own attendance" on public.attendance;
create policy "Gym can delete own attendance"
on public.attendance
for delete
to authenticated
using (gym_id = public.current_gym_id());
