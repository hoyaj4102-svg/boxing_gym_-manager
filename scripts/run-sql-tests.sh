#!/usr/bin/env bash
# Runs supabase/*_test.sql against a disposable local Postgres database.
# Uses DATABASE_URL when set. That URL must point at localhost.
# Otherwise uses the local postgres superuser over a peer socket.
# Each assertion script ends in ROLLBACK. The database is dropped at the end.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

DB_NAME="ci_sql_tests"

if [[ -n "${DATABASE_URL:-}" ]]; then
  python3 - <<'PY'
import os
from urllib.parse import urlparse

parsed = urlparse(os.environ["DATABASE_URL"])
host = (parsed.hostname or "").lower().rstrip(".")
if host not in {"localhost", "127.0.0.1", "::1"}:
    raise SystemExit(
        "Refusing to run SQL tests: DATABASE_URL is not a local disposable database."
    )
PY
fi

psql_admin() {
  if [[ -n "${DATABASE_URL:-}" ]]; then
    psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -c "set client_min_messages to warning" "$@"
  else
    sudo -u postgres psql -X -v ON_ERROR_STOP=1 -c "set client_min_messages to warning" "$@"
  fi
}

psql_db() {
  local db="$1"
  shift
  if [[ -n "${DATABASE_URL:-}" ]]; then
    local admin="${DATABASE_URL%/*}"
    admin="${admin%%\?*}"
    psql "${admin}/${db}" -X -v ON_ERROR_STOP=1 "$@"
  else
    sudo -u postgres psql -d "$db" -X -v ON_ERROR_STOP=1 "$@"
  fi
}

drop_db() {
  psql_admin -c "select pg_terminate_backend(pid) from pg_stat_activity where datname = '${DB_NAME}' and pid <> pg_backend_pid();" >/dev/null || true
  psql_admin -c "drop database if exists ${DB_NAME};" >/dev/null || true
}

trap drop_db EXIT

drop_db
psql_admin -c "create database ${DB_NAME};" >/dev/null

schema_files=(
  scripts/ci/local_postgres_bootstrap.sql
  supabase/schema.sql
  supabase/add_member_address.sql
  supabase/billing.sql
  supabase/checkout_sessions.sql
  supabase/cancel_subscription.sql
  supabase/monthly_billing.sql
  supabase/member_restore.sql
  supabase/payment_attempts.sql
  supabase/p0_2_payment_claim.sql
  supabase/p1_5_calendar_month_billing.sql
  supabase/p1_1_auto_renewal_reconciliation.sql
  supabase/p1_2_toss_webhook_events.sql
  supabase/p1_6_payment_history.sql
  supabase/p1_7_initial_billing_idempotency.sql
  supabase/p1_7b_initial_billing_reconciliation.sql
  supabase/p1_14c_expired_pro_access_enforcement.sql
)

declare -A applied_schema=()
for file in "${schema_files[@]}"; do
  if [[ ! -f "$file" ]]; then
    echo "Missing schema file: ${file}" >&2
    exit 1
  fi
  psql_db "$DB_NAME" -q -c "set client_min_messages to warning" -f "$file" >/dev/null
  applied_schema["$file"]=1
done

while IFS= read -r file; do
  if [[ -n "${applied_schema[$file]:-}" ]]; then
    continue
  fi
  case "$file" in
    *_test.sql|*rollback*)
      continue
      ;;
  esac
  echo "Applying additional SQL file: ${file}"
  psql_db "$DB_NAME" -q -c "set client_min_messages to warning" -f "$file" >/dev/null
done < <(find supabase -maxdepth 1 -type f -name '*.sql' | sort)

mapfile -t test_files < <(find supabase -maxdepth 1 -type f -name '*_test.sql' | sort)
if [[ ${#test_files[@]} -eq 0 ]]; then
  echo "No SQL test files found." >&2
  exit 1
fi

summary_file="$(mktemp)"
cleanup_summary() {
  rm -f "$summary_file"
}
trap 'cleanup_summary; drop_db' EXIT

for file in "${test_files[@]}"; do
  csv_file="$(mktemp)"
  notice_file="$(mktemp)"
  set +e
  psql_db "$DB_NAME" -q --csv -f "$file" >"$csv_file" 2>"$notice_file"
  psql_status=$?
  set -e
  if [[ -s "$notice_file" ]]; then
    cat "$notice_file" >&2
  fi
  if [[ "$psql_status" -ne 0 ]]; then
    echo "SQL test command failed: ${file}" >&2
  fi
  python3 - "$file" "$csv_file" "$summary_file" "$psql_status" "$notice_file" <<'PY'
import csv
import re
import sys

path, csv_path, summary_path, psql_status, notice_path = sys.argv[1:]
passed = 0
failed = 0
failures = []
with open(csv_path, newline="") as handle:
    for row in csv.reader(handle):
        if len(row) < 2:
            continue
        status = row[1].strip()
        if status not in {"PASS", "FAIL"}:
            continue
        if status == "PASS":
            passed += 1
        else:
            failed += 1
            detail = row[2] if len(row) > 2 else ""
            failures.append(f"{row[0]}: {detail}")

if passed == 0 and failed == 0:
    seen = {}
    with open(notice_path, encoding="utf-8", errors="replace") as handle:
        for match in re.finditer(r"NOTICE:\s+(PASS|FAIL):\s+(.+)", handle.read()):
            status, rest = match.group(1), match.group(2).strip()
            name = re.split(r"\s+\(", rest, maxsplit=1)[0].strip()
            if not name:
                continue
            if name not in seen or status == "FAIL":
                seen[name] = status
    passed = sum(1 for status in seen.values() if status == "PASS")
    failed = sum(1 for status in seen.values() if status == "FAIL")
    failures = [name for name, status in seen.items() if status == "FAIL"]

print(f"{path}: {passed} passed, {failed} failed")
if psql_status != "0" or passed == 0 or failed:
    if passed == 0:
        print(f"SQL test produced no passing results: {path}", file=sys.stderr)
    for line in failures:
        print(line, file=sys.stderr)
    sys.exit(1)
with open(summary_path, "a", encoding="utf-8") as summary:
    summary.write(f"{passed}\n")
PY
  rm -f "$csv_file" "$notice_file"
done

total_passed="$(awk '{s+=$1} END {print s+0}' "$summary_file")"
echo "SQL tests passed: ${#test_files[@]} files, ${total_passed} assertions"
