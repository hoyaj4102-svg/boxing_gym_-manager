-- =============================================================================
-- Migration name: p1_31_prebackup_billing_credentials_20261125
-- Migration version: 20261124231918
--
-- Already applied on hosted Supabase before p1_31. Do not re-apply it there.
-- Copies private.billing_credentials as it exists at this point, turns on
-- row level security, and leaves the table readable only by its owner.
-- The copy does not print credential values.
--
-- requires Founder approval before applying to any database that does not
-- already have this version recorded.
-- =============================================================================

create schema if not exists private;

do $prebackup_source$
begin
  if to_regclass('private.billing_credentials') is null then
    raise exception
      'private.billing_credentials must exist before p1_31_prebackup_billing_credentials_20261125';
  end if;
end
$prebackup_source$;

create table if not exists private.billing_credentials_backup_20261125
  (like private.billing_credentials including defaults);

insert into private.billing_credentials_backup_20261125
select source_row.*
from private.billing_credentials as source_row
where not exists (
  select 1
  from private.billing_credentials_backup_20261125
);

alter table private.billing_credentials_backup_20261125 enable row level security;

revoke all on table private.billing_credentials_backup_20261125 from public;
revoke all on table private.billing_credentials_backup_20261125 from anon, authenticated;
revoke all on table private.billing_credentials_backup_20261125 from service_role;

comment on table private.billing_credentials_backup_20261125 is
  'Owner-only snapshot of billing_credentials taken before p1_31. Version 20261124231918.';
