-- =============================================================================
-- P1-2 Toss webhook audit / idempotency
-- Run after schema.sql
-- =============================================================================

create table if not exists public.toss_webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider text not null default 'toss' check (provider = 'toss'),
  transmission_id text not null,
  event_type text not null default '',
  order_id text,
  payment_key text,
  received_payload jsonb not null default '{}'::jsonb,
  verification_status text not null default 'unverified',
  processing_status text not null default 'received',
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create unique index if not exists toss_webhook_events_provider_transmission_uidx
  on public.toss_webhook_events (provider, transmission_id);

create index if not exists toss_webhook_events_order_id_idx
  on public.toss_webhook_events (order_id);

create index if not exists toss_webhook_events_processing_status_idx
  on public.toss_webhook_events (processing_status);

drop trigger if exists toss_webhook_events_set_updated_at on public.toss_webhook_events;
create trigger toss_webhook_events_set_updated_at
before update on public.toss_webhook_events
for each row
execute function public.set_updated_at();

alter table public.toss_webhook_events enable row level security;

revoke all on table public.toss_webhook_events from public;
revoke all on table public.toss_webhook_events from anon, authenticated;
grant select, insert, update on table public.toss_webhook_events to service_role;

-- No anon/authenticated policies. Webhook audit writes are service-role only.
