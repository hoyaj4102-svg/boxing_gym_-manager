#!/usr/bin/env bash
# Disposable Postgres checks for the combined billing SQL.
# Uses DATABASE_URL when set. Otherwise uses the local postgres superuser.
# Every assertion script ends in ROLLBACK.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

psql_admin() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" -v ON_ERROR_STOP=1 "$@"
  else
    sudo -u postgres psql -v ON_ERROR_STOP=1 "$@"
  fi
}

psql_db() {
  local db="$1"
  shift
  if [[ -n "${DATABASE_URL:-}" ]]; then
    local admin="${DATABASE_URL%/*}"
    psql "${admin}/${db}" -v ON_ERROR_STOP=1 "$@"
  else
    sudo -u postgres psql -d "$db" -v ON_ERROR_STOP=1 "$@"
  fi
}

recreate_db() {
  local db="$1"
  psql_admin -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${db}' and pid <> pg_backend_pid();" >/dev/null
  psql_admin -c "drop database if exists ${db};"
  psql_admin -c "create database ${db};"
}

apply_base() {
  local db="$1"
  local file
  for file in \
    supabase/ci_local_postgres_bootstrap.sql \
    supabase/schema.sql \
    supabase/billing.sql \
    supabase/checkout_sessions.sql \
    supabase/cancel_subscription.sql \
    supabase/monthly_billing.sql \
    supabase/payment_attempts.sql \
    supabase/p0_2_payment_claim.sql \
    supabase/p1_5_calendar_month_billing.sql \
    supabase/p1_14c_expired_pro_access_enforcement.sql \
    supabase/p1_15a_expired_pro_billing_claim_rollback.sql
  do
    psql_db "$db" -f "$file" >/dev/null
  done
}

require_no_fail() {
  local label="$1"
  local db="$2"
  local file="$3"
  local output
  output="$(psql_db "$db" -f "$file")"
  printf '%s\n' "$output"
  if printf '%s\n' "$output" | grep -E '(^|[[:space:]])FAIL([[:space:]]|$)' >/dev/null; then
    echo "Check failed: ${label}" >&2
    exit 1
  fi
}

run_order() {
  local db="$1"
  shift
  recreate_db "$db"
  apply_base "$db"
  local file
  for file in "$@"; do
    psql_db "$db" -f "$file" >/dev/null
  done
  for file in "$@"; do
    psql_db "$db" -f "$file" >/dev/null
  done
  echo "Order ${db}: SQL applied twice"
  psql_db "$db" -f supabase/p0_integrate_payment_claim_test.sql
  psql_db "$db" -f supabase/p0_payment_data_protection_test.sql
  require_no_fail "expired plan claim" "$db" supabase/p1_15a_expired_pro_billing_claim_test.sql
  require_no_fail "initial billing" "$db" supabase/p1_7_initial_billing_idempotency_test.sql
  require_no_fail "duplicate guard" "$db" supabase/p1_9c_initial_auto_renewal_duplicate_guard_test.sql
  psql_admin -c "drop database if exists ${db};" >/dev/null
}

run_order payment_order_data_then_claim \
  supabase/p0_payment_data_protection.sql \
  supabase/p1_15a_expired_pro_billing_claim.sql

run_order payment_order_claim_then_data \
  supabase/p1_15a_expired_pro_billing_claim.sql \
  supabase/p0_payment_data_protection.sql

echo "Payment integration checks passed."
