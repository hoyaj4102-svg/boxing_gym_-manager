-- =============================================================================
-- p1_30 Signup acquisition source.
--
-- Records how a new account arrived: utm_source, utm_medium, utm_campaign,
-- and optionally utm_content and utm_term, plus the referrer domain and the
-- landing path. Marketing links use ?utm_source=threads.
--
-- Not stored: the raw URL query, IP address, device fingerprint, or email.
-- Each value is length-limited and restricted to a safe character set.
-- Invalid fields are dropped. Signup still creates the gym.
--
-- The client keeps the values briefly, then sends them in signup user
-- metadata. The insert trigger sanitizes them again, links the row to the
-- new auth user and gym, and removes the metadata key so the payload is
-- not kept on auth.users.
--
-- Row level security is on. authenticated may select only its own row.
-- anon has no privileges. There is no insert, update, or delete grant for
-- anon, authenticated, or service_role. service_role may select (operators).
-- The trigger is security definer and is the only writer.
--
-- Idempotent. Re-applying replaces the functions, policy, and trigger and
-- does not rewrite existing rows.
--
-- This file is not run by Vercel preview or by CI against the hosted
-- database. Preview deploys static files only. There is no
-- supabase/migrations history for a hosted integration to apply. Run it
-- on a local disposable database until a separate approval.
--
-- Undo with supabase/p1_30_signup_acquisition_rollback.sql.
-- =============================================================================

create table if not exists public.signup_acquisitions (
  user_id uuid primary key references auth.users (id) on delete cascade,
  gym_id uuid not null references public.gyms (id) on delete cascade,
  utm_source text,
  utm_medium text,
  utm_campaign text,
  utm_content text,
  utm_term text,
  referrer_domain text,
  landing_path text,
  captured_at timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint signup_acquisitions_utm_source_safe check (
    utm_source is null
    or (
      char_length(utm_source) between 1 and 64
      and utm_source ~ '^[A-Za-z0-9._~-]+$'
    )
  ),
  constraint signup_acquisitions_utm_medium_safe check (
    utm_medium is null
    or (
      char_length(utm_medium) between 1 and 64
      and utm_medium ~ '^[A-Za-z0-9._~-]+$'
    )
  ),
  constraint signup_acquisitions_utm_campaign_safe check (
    utm_campaign is null
    or (
      char_length(utm_campaign) between 1 and 64
      and utm_campaign ~ '^[A-Za-z0-9._~-]+$'
    )
  ),
  constraint signup_acquisitions_utm_content_safe check (
    utm_content is null
    or (
      char_length(utm_content) between 1 and 64
      and utm_content ~ '^[A-Za-z0-9._~-]+$'
    )
  ),
  constraint signup_acquisitions_utm_term_safe check (
    utm_term is null
    or (
      char_length(utm_term) between 1 and 64
      and utm_term ~ '^[A-Za-z0-9._~-]+$'
    )
  ),
  constraint signup_acquisitions_referrer_domain_safe check (
    referrer_domain is null
    or referrer_domain = 'localhost'
    or (
      char_length(referrer_domain) between 1 and 253
      and referrer_domain !~ ':'
      and referrer_domain !~ '^[0-9.]+$'
      and referrer_domain ~ '[a-z]'
      and referrer_domain ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
    )
  ),
  constraint signup_acquisitions_landing_path_safe check (
    landing_path is null
    or (
      char_length(landing_path) between 1 and 128
      and landing_path ~ '^/[A-Za-z0-9/_.~-]*$'
      and landing_path !~ '\.\.'
      and landing_path !~ '//'
    )
  ),
  constraint signup_acquisitions_has_source check (
    utm_source is not null
    or utm_medium is not null
    or utm_campaign is not null
    or utm_content is not null
    or utm_term is not null
    or referrer_domain is not null
    or landing_path is not null
  )
);

create index if not exists signup_acquisitions_gym_id_idx
  on public.signup_acquisitions (gym_id);

comment on table public.signup_acquisitions is
  'Signup attribution: safe UTM tokens, referrer domain, and landing path. No email, IP, fingerprint, or raw query.';

alter table public.signup_acquisitions enable row level security;

revoke all on table public.signup_acquisitions from public;
revoke all on table public.signup_acquisitions from anon;
revoke all on table public.signup_acquisitions from authenticated;
revoke all on table public.signup_acquisitions from service_role;
grant select on table public.signup_acquisitions to authenticated;
grant select on table public.signup_acquisitions to service_role;

drop policy if exists "Owner can view own signup acquisition" on public.signup_acquisitions;
create policy "Owner can view own signup acquisition"
on public.signup_acquisitions
for select
to authenticated
using (
  user_id = auth.uid()
  and gym_id = public.current_gym_id()
);

create or replace function public.signup_acquisition_token(p_value text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when cleaned is null then null
    when char_length(cleaned) > 64 then null
    when cleaned ~ '^[A-Za-z0-9._~-]+$' then cleaned
    else null
  end
  from (select nullif(btrim(p_value), '') as cleaned) s
$$;

create or replace function public.signup_acquisition_domain(p_value text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when cleaned is null then null
    when char_length(cleaned) > 253 then null
    when position(':' in cleaned) > 0 then null
    when cleaned = 'localhost' then cleaned
    when cleaned ~ '^[0-9.]+$' then null
    when cleaned !~ '[a-z]' then null
    when cleaned ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$'
      then cleaned
    else null
  end
  from (select nullif(lower(btrim(p_value)), '') as cleaned) s
$$;

create or replace function public.signup_acquisition_path(p_value text)
returns text
language sql
immutable
set search_path = public
as $$
  select case
    when cleaned is null then null
    when char_length(cleaned) > 128 then null
    when cleaned !~ '^/[A-Za-z0-9/_.~-]*$' then null
    when position('..' in cleaned) > 0 then null
    when position('//' in cleaned) > 0 then null
    else cleaned
  end
  from (select nullif(btrim(p_value), '') as cleaned) s
$$;

create or replace function public.signup_acquisition_clean(p_input jsonb)
returns jsonb
language plpgsql
stable
set search_path = public
as $$
declare
  v_source text;
  v_medium text;
  v_campaign text;
  v_content text;
  v_term text;
  v_domain text;
  v_path text;
  v_captured timestamptz;
begin
  if p_input is null or jsonb_typeof(p_input) is distinct from 'object' then
    return null;
  end if;

  v_source := public.signup_acquisition_token(p_input->>'utm_source');
  v_medium := public.signup_acquisition_token(p_input->>'utm_medium');
  v_campaign := public.signup_acquisition_token(p_input->>'utm_campaign');
  v_content := public.signup_acquisition_token(p_input->>'utm_content');
  v_term := public.signup_acquisition_token(p_input->>'utm_term');
  v_domain := public.signup_acquisition_domain(p_input->>'referrer_domain');
  v_path := public.signup_acquisition_path(p_input->>'landing_path');

  if v_source is null
     and v_medium is null
     and v_campaign is null
     and v_content is null
     and v_term is null
     and v_domain is null
     and v_path is null then
    return null;
  end if;

  begin
    v_captured := nullif(p_input->>'captured_at', '')::timestamptz;
  exception
    when others then
      v_captured := null;
  end;

  if v_captured is null
     or v_captured < pg_catalog.now() - interval '2 hours'
     or v_captured > pg_catalog.now() + interval '5 minutes' then
    v_captured := pg_catalog.now();
  end if;

  return jsonb_build_object(
    'utm_source', v_source,
    'utm_medium', v_medium,
    'utm_campaign', v_campaign,
    'utm_content', v_content,
    'utm_term', v_term,
    'referrer_domain', v_domain,
    'landing_path', v_path,
    'captured_at', v_captured
  );
end;
$$;

create or replace function public.record_signup_acquisition()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_raw jsonb;
  v_clean jsonb;
  v_gym_id uuid;
begin
  v_raw := new.raw_user_meta_data;

  if v_raw is not null and v_raw ? 'acquisition' then
    update auth.users
    set raw_user_meta_data = v_raw - 'acquisition'
    where id = new.id;
  end if;

  if v_raw is null or jsonb_typeof(v_raw->'acquisition') is distinct from 'object' then
    return new;
  end if;

  v_clean := public.signup_acquisition_clean(v_raw->'acquisition');
  if v_clean is null then
    return new;
  end if;

  select p.gym_id
  into v_gym_id
  from public.profiles p
  where p.id = new.id;

  if v_gym_id is null then
    return new;
  end if;

  insert into public.signup_acquisitions (
    user_id,
    gym_id,
    utm_source,
    utm_medium,
    utm_campaign,
    utm_content,
    utm_term,
    referrer_domain,
    landing_path,
    captured_at
  ) values (
    new.id,
    v_gym_id,
    v_clean->>'utm_source',
    v_clean->>'utm_medium',
    v_clean->>'utm_campaign',
    v_clean->>'utm_content',
    v_clean->>'utm_term',
    v_clean->>'referrer_domain',
    v_clean->>'landing_path',
    coalesce((v_clean->>'captured_at')::timestamptz, pg_catalog.now())
  )
  on conflict (user_id) do nothing;

  return new;
end;
$$;

-- Hosted Supabase grants execute on a new public function to anon,
-- authenticated, and service_role, plus the Postgres default public grant.
-- These helpers are trigger internals. Revoke every API role.
revoke all on function public.signup_acquisition_token(text) from public;
revoke all on function public.signup_acquisition_token(text) from anon;
revoke all on function public.signup_acquisition_token(text) from authenticated;
revoke all on function public.signup_acquisition_token(text) from service_role;

revoke all on function public.signup_acquisition_domain(text) from public;
revoke all on function public.signup_acquisition_domain(text) from anon;
revoke all on function public.signup_acquisition_domain(text) from authenticated;
revoke all on function public.signup_acquisition_domain(text) from service_role;

revoke all on function public.signup_acquisition_path(text) from public;
revoke all on function public.signup_acquisition_path(text) from anon;
revoke all on function public.signup_acquisition_path(text) from authenticated;
revoke all on function public.signup_acquisition_path(text) from service_role;

revoke all on function public.signup_acquisition_clean(jsonb) from public;
revoke all on function public.signup_acquisition_clean(jsonb) from anon;
revoke all on function public.signup_acquisition_clean(jsonb) from authenticated;
revoke all on function public.signup_acquisition_clean(jsonb) from service_role;

revoke all on function public.record_signup_acquisition() from public;
revoke all on function public.record_signup_acquisition() from anon;
revoke all on function public.record_signup_acquisition() from authenticated;
revoke all on function public.record_signup_acquisition() from service_role;

-- Name sorts after on_auth_user_created so the gym and profile exist first.
drop trigger if exists on_auth_user_created_acquisition on auth.users;
create trigger on_auth_user_created_acquisition
after insert on auth.users
for each row
execute function public.record_signup_acquisition();
