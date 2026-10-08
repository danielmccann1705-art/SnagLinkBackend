#!/bin/zsh
set -euo pipefail
set +x

config_path="${1:-/Users/danielmccann/.config/snaglist/measurement/posthog-sandbox.json}"
output_path="${2:-/tmp/posthog-sandbox-smoke.json}"
container="snaglist-posthog-smoke-$RANDOM"

cleanup() {
  docker rm -f "$container" >/dev/null 2>&1 || true
}
trap cleanup EXIT INT TERM

python3 - "$config_path" <<'PY'
import json, os, stat, sys
path = sys.argv[1]
mode = stat.S_IMODE(os.stat(path).st_mode)
with open(path, encoding="utf-8") as handle:
    value = json.load(handle)
assert mode & 0o077 == 0, "configuration must be private"
assert value.get("host") == "https://eu.i.posthog.com"
assert value.get("projectId") == 298161
assert value.get("environment") == "sandbox"
token = value.get("publicWriteToken")
assert isinstance(token, str) and token.startswith("phc_") and len(token) <= 4096
PY

docker run --rm -d --name "$container" \
  -e POSTGRES_USER=snaglist -e POSTGRES_PASSWORD=snaglist \
  -e POSTGRES_DB=snaglist_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null

for attempt in {1..40}; do
  port="$(docker port "$container" 5432/tcp | sed 's/.*://')"
  if docker exec "$container" pg_isready -U snaglist -d snaglist_test >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

export DATABASE_URL="postgres://snaglist:snaglist@127.0.0.1:${port}/snaglist_test"
export JWT_SECRET="synthetic-posthog-smoke-signing-key-32-bytes"
export POSTHOG_SANDBOX_SMOKE_CONFIG="$config_path"
export POSTHOG_SANDBOX_SMOKE_OUTPUT="$output_path"

swift test --build-system native --disable-sandbox --jobs 4 \
  -Xswiftc -swift-version -Xswiftc 5 \
  --filter 'PostHogSandboxSmokeTests/testRealProductOutboxReachesGuardedEUSandbox'

python3 - "$output_path" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)
print("PostHog EU sandbox outbound capture smoke passed")
print(f"Manifest: {sys.argv[1]}")
print(f"Expected delivered events: {value['expectedDeliveredCount']}")
PY
