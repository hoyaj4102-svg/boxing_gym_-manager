-- Add optional member address field.
-- Run in Supabase SQL Editor before using the address field in production.

alter table public.members
  add column if not exists address text not null default '';
