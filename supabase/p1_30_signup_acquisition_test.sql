-- Synthetic signup attribution checks. This script rolls back.
-- Ids are generated here. No production row is read or written.
-- The migration is applied by the local test runner before this file.

begin;

create temp table p1_30_results (
  test_name text primary key,
  status text not null check (status in ('PASS', 'FAIL')),
  detail text not null
) on commit drop;

create temp table p1_30_context (
  with_utm uuid not null,
  without_utm uuid not null,
  invalid_mix uuid not null,
  raw_query uuid not null,
  after_reapply uuid not null
) on commit drop;

insert into p1_30_context
values (
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid(),
  gen_random_uuid()
);

create or replace function pg_temp.p1_30_expect(p_name text, p_ok boolean, p_detail text)
returns void
language sql
as $$
  insert into p1_30_results (test_name, status, detail)
  values (
    p_name,
    case when p_ok then 'PASS' else 'FAIL' end,
    coalesce(p_detail, '')
  );
$$;

create or replace function pg_temp.p1_30_signup(p_user uuid, p_label text, p_meta jsonb)
returns void
language plpgsql
as $$
begin
  insert into auth.users (
    id,
    aud,
    role,
    email,
    raw_app_meta_data,
    raw_user_meta_data
  ) values (
    p_user,
    'authenticated',
    'authenticated',
    p_label,
    '{"provider":"email","providers":["email"]}'::jsonb,
    jsonb_build_object(
      'gym_name', 'Synthetic Gym',
      'owner_name', 'Synthetic Owner',
      'phone', '',
      'locale', 'ko'
    ) || coalesce(p_meta, '{}'::jsonb)
  );
end;
$$;

revoke all on function pg_temp.p1_30_expect(text, boolean, text) from public;
revoke all on function pg_temp.p1_30_signup(uuid, text, jsonb) from public;

do $$
declare
  v_with uuid;
  v_without uuid;
  v_invalid uuid;
  v_raw uuid;
  v_count integer;
  v_gym_a uuid;
  v_gym_b uuid;
  v_ok boolean;
  v_detail text;
  v_source text;
  v_medium text;
  v_campaign text;
  v_content text;
  v_term text;
  v_domain text;
  v_path text;
  v_linked boolean;
  v_meta text;
  v_captured timestamptz;
begin
  select with_utm, without_utm, invalid_mix, raw_query
  into v_with, v_without, v_invalid, v_raw
  from p1_30_context;

  perform pg_temp.p1_30_expect(
    'token accepts threads and 64 safe characters',
    public.signup_acquisition_token('threads') = 'threads'
      and public.signup_acquisition_token(repeat('a', 64)) = repeat('a', 64),
    ''
  );
  perform pg_temp.p1_30_expect(
    'token rejects long, spaced, and contact-shaped values',
    public.signup_acquisition_token(repeat('a', 65)) is null
      and public.signup_acquisition_token('bad term') is null
      and public.signup_acquisition_token('owner@example.invalid') is null
      and public.signup_acquisition_token('threads<script>') is null
      and public.signup_acquisition_token('utm_source=threads') is null,
    ''
  );
  perform pg_temp.p1_30_expect(
    'domain keeps a hostname and rejects urls and addresses',
    public.signup_acquisition_domain('L.Threads.net') = 'l.threads.net'
      and public.signup_acquisition_domain('https://threads.net/path?utm_source=threads') is null
      and public.signup_acquisition_domain('203.0.113.10') is null
      and public.signup_acquisition_domain('2001:db8::1') is null,
    ''
  );
  perform pg_temp.p1_30_expect(
    'path keeps a route and rejects a query',
    public.signup_acquisition_path('/') = '/'
      and public.signup_acquisition_path('/signup') = '/signup'
      and public.signup_acquisition_path('/signup?utm_source=threads') is null
      and public.signup_acquisition_path('/../secret') is null,
    ''
  );

  perform pg_temp.p1_30_signup(
    v_with,
    'synthetic-with-utm',
    jsonb_build_object(
      'acquisition', jsonb_build_object(
        'utm_source', 'threads',
        'utm_medium', 'social',
        'utm_campaign', 'launch',
        'utm_content', 'bio',
        'utm_term', 'boxing',
        'referrer_domain', 'l.threads.net',
        'landing_path', '/',
        'captured_at', to_char(now() at time zone 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS"Z"'),
        'email', 'synthetic-hidden',
        'ip', '203.0.113.10',
        'query', '?utm_source=threads'
      )
    )
  );
  perform pg_temp.p1_30_signup(v_without, 'synthetic-without-utm', '{}'::jsonb);
  perform pg_temp.p1_30_signup(
    v_invalid,
    'synthetic-invalid-mix',
    jsonb_build_object(
      'acquisition', jsonb_build_object(
        'utm_source', 'threads<script>',
        'utm_medium', 'owner@example.invalid',
        'utm_campaign', repeat('a', 65),
        'utm_content', 'bio_link',
        'utm_term', 'bad term',
        'referrer_domain', 'https://threads.net/path?utm_source=threads',
        'landing_path', '/signup?utm_source=threads',
        'email', 'synthetic-hidden',
        'ip', '203.0.113.10',
        'query', '?utm_source=threads',
        'captured_at', 'not-a-timestamp'
      )
    )
  );
  perform pg_temp.p1_30_signup(
    v_raw,
    'synthetic-raw-query',
    jsonb_build_object(
      'acquisition', 'https://threads.net/path?utm_source=threads&email=synthetic-hidden'
    )
  );

  select
    sa.utm_source,
    sa.utm_medium,
    sa.utm_campaign,
    sa.utm_content,
    sa.utm_term,
    sa.referrer_domain,
    sa.landing_path,
    sa.captured_at,
    sa.gym_id = p.gym_id and sa.user_id = p.id
  into
    v_source, v_medium, v_campaign, v_content, v_term, v_domain, v_path, v_captured, v_linked
  from public.signup_acquisitions sa
  join public.profiles p on p.id = sa.user_id
  where sa.user_id = v_with;

  perform pg_temp.p1_30_expect(
    'signup with utm links the safe fields to the account and gym',
    v_source = 'threads'
      and v_medium = 'social'
      and v_campaign = 'launch'
      and v_content = 'bio'
      and v_term = 'boxing'
      and v_domain = 'l.threads.net'
      and v_path = '/'
      and v_linked
      and abs(extract(epoch from v_captured - now())) < 120,
    coalesce(v_source, 'missing')
  );

  perform pg_temp.p1_30_expect(
    'signup without utm still creates a gym and stores no acquisition',
    exists (select 1 from public.profiles p where p.id = v_without)
      and exists (select 1 from public.gyms g join public.profiles p on p.gym_id = g.id where p.id = v_without)
      and not exists (select 1 from public.signup_acquisitions sa where sa.user_id = v_without),
    ''
  );

  select
    sa.utm_source,
    sa.utm_medium,
    sa.utm_campaign,
    sa.utm_content,
    sa.utm_term,
    sa.referrer_domain,
    sa.landing_path
  into v_source, v_medium, v_campaign, v_content, v_term, v_domain, v_path
  from public.signup_acquisitions sa
  where sa.user_id = v_invalid;

  perform pg_temp.p1_30_expect(
    'invalid values are dropped and a safe field is kept',
    v_source is null
      and v_medium is null
      and v_campaign is null
      and v_content = 'bio_link'
      and v_term is null
      and v_domain is null
      and v_path is null
      and position('@' in coalesce(v_content, '')) = 0
      and position('?' in coalesce(v_content, '')) = 0,
    coalesce(v_content, 'missing')
  );

  perform pg_temp.p1_30_expect(
    'a raw query string is not stored',
    not exists (select 1 from public.signup_acquisitions sa where sa.user_id = v_raw)
      and exists (select 1 from public.profiles p where p.id = v_raw),
    ''
  );

  select string_agg(u.raw_user_meta_data::text, ' ')
  into v_meta
  from auth.users u
  where u.id in (v_with, v_without, v_invalid, v_raw);

  perform pg_temp.p1_30_expect(
    'signup metadata does not keep the acquisition payload',
    not exists (
      select 1
      from auth.users u
      where u.id in (v_with, v_without, v_invalid, v_raw)
        and u.raw_user_meta_data ? 'acquisition'
    )
      and position('https:' in coalesce(v_meta, '')) = 0
      and position('utm_source=' in coalesce(v_meta, '')) = 0
      and position('203.0.113' in coalesce(v_meta, '')) = 0
      and position('@' in coalesce(v_meta, '')) = 0,
    ''
  );

  perform pg_temp.p1_30_expect(
    'the acquisition table has no contact or raw-query columns',
    not exists (
      select 1
      from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = 'signup_acquisitions'
        and c.column_name in (
          'email', 'ip', 'ip_address', 'fingerprint', 'query', 'raw_query', 'referrer', 'user_agent'
        )
    ),
    ''
  );

  perform pg_temp.p1_30_expect(
    'anon and clients cannot write and operators can read',
    has_table_privilege('anon', 'public.signup_acquisitions', 'SELECT') = false
      and has_table_privilege('anon', 'public.signup_acquisitions', 'INSERT') = false
      and has_table_privilege('anon', 'public.signup_acquisitions', 'UPDATE') = false
      and has_table_privilege('anon', 'public.signup_acquisitions', 'DELETE') = false
      and has_table_privilege('authenticated', 'public.signup_acquisitions', 'SELECT') = true
      and has_table_privilege('authenticated', 'public.signup_acquisitions', 'INSERT') = false
      and has_table_privilege('authenticated', 'public.signup_acquisitions', 'UPDATE') = false
      and has_table_privilege('authenticated', 'public.signup_acquisitions', 'DELETE') = false
      and has_table_privilege('service_role', 'public.signup_acquisitions', 'SELECT') = true
      and has_table_privilege('service_role', 'public.signup_acquisitions', 'INSERT') = false
      and has_function_privilege('anon', 'public.record_signup_acquisition()', 'EXECUTE') = false
      and has_function_privilege('authenticated', 'public.signup_acquisition_clean(jsonb)', 'EXECUTE') = false
      and exists (
        select 1
        from pg_class c
        where c.oid = 'public.signup_acquisitions'::regclass
          and c.relrowsecurity
          and not c.relforcerowsecurity
      ),
    ''
  );

  begin
    execute 'set local role anon';
    perform 1 from public.signup_acquisitions;
    execute 'reset role';
    v_ok := false;
    v_detail := 'select succeeded';
  exception
    when insufficient_privilege then
      execute 'reset role';
      v_ok := true;
      v_detail := 'denied';
    when others then
      execute 'reset role';
      v_ok := false;
      v_detail := sqlstate;
  end;
  perform pg_temp.p1_30_expect('anon cannot read signup acquisition', v_ok, v_detail);

  select p.gym_id into v_gym_a from public.profiles p where p.id = v_with;
  begin
    execute 'set local role anon';
    insert into public.signup_acquisitions (user_id, gym_id, landing_path)
    values (v_without, v_gym_a, '/');
    execute 'reset role';
    v_ok := false;
    v_detail := 'insert succeeded';
  exception
    when insufficient_privilege then
      execute 'reset role';
      v_ok := true;
      v_detail := 'denied';
    when others then
      execute 'reset role';
      v_ok := false;
      v_detail := sqlstate;
  end;
  perform pg_temp.p1_30_expect('anon cannot write signup acquisition', v_ok, v_detail);

  perform set_config('request.jwt.claim.sub', v_with::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.signup_acquisitions;
  execute 'reset role';
  perform pg_temp.p1_30_expect(
    'the owner can read only their own acquisition',
    v_count = 1,
    coalesce(v_count::text, 'null')
  );

  select p.gym_id into v_gym_b from public.profiles p where p.id = v_without;
  update public.signup_acquisitions
  set gym_id = v_gym_b
  where user_id = v_with;
  perform set_config('request.jwt.claim.sub', v_with::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.signup_acquisitions;
  execute 'reset role';
  update public.signup_acquisitions
  set gym_id = v_gym_a
  where user_id = v_with;
  perform pg_temp.p1_30_expect(
    'the owner cannot read a row linked to another gym',
    v_count = 0,
    coalesce(v_count::text, 'null')
  );

  perform set_config('request.jwt.claim.sub', v_without::text, true);
  execute 'set local role authenticated';
  select count(*) into v_count from public.signup_acquisitions;
  execute 'reset role';
  perform pg_temp.p1_30_expect(
    'another gym cannot read this acquisition',
    v_count = 0,
    coalesce(v_count::text, 'null')
  );

  begin
    perform set_config('request.jwt.claim.sub', v_without::text, true);
    execute 'set local role authenticated';
    insert into public.signup_acquisitions (user_id, gym_id, utm_source)
    values (v_without, v_gym_b, 'threads');
    execute 'reset role';
    v_ok := false;
    v_detail := 'insert succeeded';
  exception
    when insufficient_privilege then
      execute 'reset role';
      v_ok := true;
      v_detail := 'denied';
    when others then
      execute 'reset role';
      v_ok := false;
      v_detail := sqlstate;
  end;
  perform pg_temp.p1_30_expect('another gym cannot write signup acquisition', v_ok, v_detail);

  execute 'set local role service_role';
  select count(*) into v_count from public.signup_acquisitions;
  execute 'reset role';
  perform pg_temp.p1_30_expect(
    'service role can read acquisition rows',
    v_count = 2,
    coalesce(v_count::text, 'null')
  );

  begin
    execute 'set local role service_role';
    insert into public.signup_acquisitions (user_id, gym_id, utm_source)
    values (v_raw, v_gym_a, 'threads');
    execute 'reset role';
    v_ok := false;
    v_detail := 'insert succeeded';
  exception
    when insufficient_privilege then
      execute 'reset role';
      v_ok := true;
      v_detail := 'denied';
    when others then
      execute 'reset role';
      v_ok := false;
      v_detail := sqlstate;
  end;
  perform pg_temp.p1_30_expect('service role cannot write signup acquisition', v_ok, v_detail);
end;
$$;

\ir p1_30_signup_acquisition.sql

do $$
declare
  v_count integer;
begin
  select count(*) into v_count
  from public.signup_acquisitions
  where utm_source = 'threads';

  perform pg_temp.p1_30_expect(
    'reapplying the migration keeps the stored row',
    v_count = 1
      and exists (
        select 1
        from pg_trigger t
        where t.tgname = 'on_auth_user_created_acquisition'
          and t.tgrelid = 'auth.users'::regclass
      ),
    coalesce(v_count::text, 'null')
  );
end;
$$;

\ir p1_30_signup_acquisition_rollback.sql

do $$
declare
  v_gyms integer;
begin
  select count(*) into v_gyms from public.gyms;
  perform pg_temp.p1_30_expect(
    'rollback drops the acquisition table and keeps gyms',
    to_regclass('public.signup_acquisitions') is null
      and not exists (
        select 1
        from pg_trigger t
        where t.tgname = 'on_auth_user_created_acquisition'
      )
      and to_regprocedure('public.record_signup_acquisition()') is null
      and exists (select 1 from public.profiles)
      and v_gyms >= 4,
    coalesce(v_gyms::text, 'null')
  );
end;
$$;

\ir p1_30_signup_acquisition.sql

do $$
declare
  v_user uuid;
  v_source text;
  v_kept boolean;
begin
  select after_reapply into v_user from p1_30_context;
  perform pg_temp.p1_30_signup(
    v_user,
    'synthetic-after-reapply',
    jsonb_build_object(
      'acquisition', jsonb_build_object(
        'utm_source', 'threads',
        'landing_path', '/signup'
      )
    )
  );

  select sa.utm_source, sa.landing_path = '/signup' and sa.gym_id = p.gym_id
  into v_source, v_kept
  from public.signup_acquisitions sa
  join public.profiles p on p.id = sa.user_id
  where sa.user_id = v_user;

  perform pg_temp.p1_30_expect(
    'signup with utm works again after rollback and reapply',
    v_source = 'threads'
      and v_kept
      and not exists (
        select 1
        from auth.users u
        where u.id = v_user
          and u.raw_user_meta_data ? 'acquisition'
      )
      and has_table_privilege('anon', 'public.signup_acquisitions', 'INSERT') = false,
    coalesce(v_source, 'missing')
  );
end;
$$;

select test_name, status, detail
from p1_30_results
order by test_name;

do $$
begin
  if exists (select 1 from p1_30_results where status <> 'PASS') then
    raise exception 'p1_30 tests failed';
  end if;
end;
$$;

rollback;
