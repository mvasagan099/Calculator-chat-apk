#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
image=postgres@sha256:2d2b8998d31037bf721cfdf764d76ba74171b4fab3431b7f72c27c56ddbdf9e3
container="calculator-sql-test-$$"
cleanup() { docker rm -f "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
docker run --name "$container" -d -e POSTGRES_HOST_AUTH_METHOD=trust "$image" -c wal_level=logical >/dev/null
for attempt in {1..30}; do
 if docker logs "$container" 2>&1 | rg -q "PostgreSQL init process complete" && docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then break; fi
 sleep 0.5
done
docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < supabase/tests/bootstrap.sql
for migration in supabase/migrations/*.sql; do
 docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < "$migration"
done
docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < supabase/remote_preflight.sql
for test in supabase/tests/authorization.sql supabase/tests/media.sql supabase/tests/status.sql supabase/tests/calls.sql supabase/tests/retention.sql supabase/tests/devices.sql supabase/tests/privacy_preferences.sql supabase/tests/advanced_calls.sql; do
 docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < "$test"
done
python3 scripts/test-call-races.py "$container"
