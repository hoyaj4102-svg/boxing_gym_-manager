-- Sweat Manager Supabase schema
-- Run this in Supabase Dashboard > SQL Editor.

create extension if not exists pgcrypto;

create table if not exists public.members (
  id text primary key default gen_random_uuid()::text,
  user_id uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name text not null,
  phone text not null default '',
  start_date date not null,
  expire_date date not null,
  pt_total integer not null default 0 check (pt_total >= 0),
  pt_remaining integer not null default 0 check (pt_remaining >= 0),
  memo text not null default '',
  last_visit date,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  attendance jsonb not null default '[]'::jsonb
);

create index if not exists members_user_id_idx on public.members(user_id);
create index if not exists members_user_expire_date_idx on public.members(user_id, expire_date);
create index if not exists members_user_last_visit_idx on public.members(user_id, last_visit);

alter table public.members enable row level security;

drop policy if exists "Users can view their own members" on public.members;
create policy "Users can view their own members"
on public.members
for select
to authenticated
using (user_id = auth.uid());

drop policy if exists "Users can insert their own members" on public.members;
create policy "Users can insert their own members"
on public.members
for insert
to authenticated
with check (user_id = auth.uid());

drop policy if exists "Users can update their own members" on public.members;
create policy "Users can update their own members"
on public.members
for update
to authenticated
using (user_id = auth.uid())
with check (user_id = auth.uid());

drop policy if exists "Users can delete their own members" on public.members;
create policy "Users can delete their own members"
on public.members
for delete
to authenticated
using (user_id = auth.uid());

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
