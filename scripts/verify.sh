#!/usr/bin/env bash
# Portable build-then-test entry point for the Snaglist backend (audit F23, 27 Sep 2026).
#
#   scripts/verify.sh                 adapter checks, then Swift build, then the full Swift suite
#   scripts/verify.sh adapter         Cloudflare adapter: npm ci, node tests, TypeScript check
#   scripts/verify.sh swift [args]    Swift build, then `swift test [args]` (e.g. --filter IssuedReportTests)
#
# The Swift suite migrates and writes to the database it is given, so it only ever
# runs against a disposable local PostgreSQL:
#   - by default a throwaway postgres:16 container on a random loopback port, removed afterwards;
#   - or SNAGLIST_TEST_DATABASE_URL=postgresql://USER:PASS@127.0.0.1:PORT/NAME for a database
#     created for this run.
# Any host other than 127.0.0.1, localhost or ::1 is refused, and an inherited DATABASE_URL is
# never used. Nothing here builds a release image, deploys, pushes, or reads a deployed secret.
# Suites that need a real R2 bucket or the staged-import fixtures skip themselves.
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
mode="${1:-all}"
[ "$#" -gt 0 ] && shift
unset DATABASE_URL

adapter() {
  echo "== Cloudflare adapter: npm ci, node tests, TypeScript"
  (cd "$here/Infrastructure/cloudflare" && npm ci --no-audit --no-fund && node --test test/*.test.mjs && npx tsc --noEmit)
}

local_host_only() {
  local rest="${1#*://}"
  rest="${rest#*@}"
  local host
  if [ "${rest#\[}" != "$rest" ]; then host="${rest#\[}"; host="${host%%\]*}"; else host="${rest%%[:/]*}"; fi
  case "$host" in
    127.0.0.1|localhost|::1) return 0 ;;
    *) echo "Refusing to run the Swift suite against '$host': only a disposable local PostgreSQL is allowed." >&2; return 1 ;;
  esac
}

container=""
cleanup() { if [ -n "$container" ]; then docker stop "$container" >/dev/null 2>&1 || true; fi; }
trap cleanup EXIT

swift_suite() {
  local url="${SNAGLIST_TEST_DATABASE_URL:-}"
  if [ -z "$url" ]; then
    command -v docker >/dev/null || { echo "Docker is needed for the disposable PostgreSQL, or set SNAGLIST_TEST_DATABASE_URL." >&2; exit 2; }
    local password port
    password="$(LC_ALL=C tr -dc 'a-z0-9' </dev/urandom | head -c 24)"
    container="snaglist-verify-$$"
    docker run -d --rm --name "$container" -e POSTGRES_USER=snaglist -e POSTGRES_PASSWORD="$password" \
      -e POSTGRES_DB=snaglist_verify -p 127.0.0.1::5432 postgres:16 >/dev/null
    port="$(docker port "$container" 5432/tcp | head -1 | sed 's/.*://')"
    for _ in $(seq 1 60); do
      docker exec "$container" pg_isready -U snaglist -d snaglist_verify >/dev/null 2>&1 && break
      sleep 1
    done
    url="postgresql://snaglist:${password}@127.0.0.1:${port}/snaglist_verify"
  fi
  local_host_only "$url" || exit 2
  echo "== Swift build"
  (cd "$here" && swift build)
  echo "== Swift tests (disposable local database)"
  (cd "$here" && DATABASE_URL="$url" DATABASE_TLS_DISABLE=true \
    JWT_SECRET="synthetic-test-only-never-a-deployed-key" BASE_URL="http://127.0.0.1:8080" \
    swift test "$@")
}

case "$mode" in
  adapter) adapter ;;
  swift) swift_suite "$@" ;;
  all) adapter; swift_suite "$@" ;;
  *) echo "usage: scripts/verify.sh [all|adapter|swift] [swift test arguments]" >&2; exit 2 ;;
esac
echo "== verify.sh $mode: passed"
