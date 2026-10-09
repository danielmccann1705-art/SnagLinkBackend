#!/bin/bash
# L7 real-transport harness for PostHog erasure (POSTHOG-DELAYED-INGESTION-OCT9.md, "L7 harness").
#
# Default: a DRY RUN against the local fake PostHog (scripts/posthog_l7_fake_server.py) with synthetic
# keys generated here. Live mode talks to EU sandbox project 298161 only and needs Dan's concrete approval
# reference (--approval-ref) and an operator handle (Codex). Keys are read only from the private 0600 files
# inside the test process; they are never passed as arguments or environment variables and never printed.
#
# Exit: 0 finished, 3 paused (resume with --resume), 2 refused before any request, 1 failed.
set -euo pipefail
set +x

usage() {
  cat <<'USAGE'
Usage: scripts/run-posthog-l7-harness.sh --project 298161 --subject-prefix <8 hex> --output-dir <abs dir> --report-name <stem>
         [--mode dry-run|live] [--late-capture after-pass-1|after-request]
         [--erasure-key-file <abs 0600 json>] [--capture-config <abs 0600 json>]
         [--approval-ref "<Dan's approval reference>"] [--operator <handle>]
         [--window-seconds N] [--real-wait-seconds N] [--poll-seconds N] [--max-run-seconds N]
         [--max-deletion-wait-seconds N] [--ingest-timeout-seconds N] [--resume] [--skip-build]
         [--fake-ingest-lag S] [--fake-person-removal-delay S] [--fake-deletion-delay S]
         [--split-after-seconds N]   (dry run only: pause after N s, then resume in a second process,
                                      exercising the resume path a live run needs while PostHog works)
Database: DATABASE_URL (loopback, disposable) when set; otherwise a throwaway postgres:16-alpine container.
USAGE
}

refuse() { echo "REFUSED: $*" >&2; exit 2; }

mode=dry-run; project=""; prefix=""; out=""; name=""; late=after-pass-1; key_file=""; capture_file=""
approval=""; operator=""; resume=0; skip_build=0; split=""
window=""; real_wait=""; poll=""; max_run=""; max_deletion_wait=""; ingest_timeout=""
fake_lag=1.0; fake_removal=1.5; fake_deletion=3.0
while [ $# -gt 0 ]; do
  case "$1" in
    --mode) mode="$2"; shift 2 ;;
    --project) project="$2"; shift 2 ;;
    --subject-prefix) prefix="$2"; shift 2 ;;
    --output-dir) out="$2"; shift 2 ;;
    --report-name) name="$2"; shift 2 ;;
    --late-capture) late="$2"; shift 2 ;;
    --erasure-key-file) key_file="$2"; shift 2 ;;
    --capture-config) capture_file="$2"; shift 2 ;;
    --approval-ref) approval="$2"; shift 2 ;;
    --operator) operator="$2"; shift 2 ;;
    --window-seconds) window="$2"; shift 2 ;;
    --real-wait-seconds) real_wait="$2"; shift 2 ;;
    --poll-seconds) poll="$2"; shift 2 ;;
    --max-run-seconds) max_run="$2"; shift 2 ;;
    --max-deletion-wait-seconds) max_deletion_wait="$2"; shift 2 ;;
    --ingest-timeout-seconds) ingest_timeout="$2"; shift 2 ;;
    --fake-ingest-lag) fake_lag="$2"; shift 2 ;;
    --fake-person-removal-delay) fake_removal="$2"; shift 2 ;;
    --fake-deletion-delay) fake_deletion="$2"; shift 2 ;;
    --split-after-seconds) split="$2"; shift 2 ;;
    --resume) resume=1; shift ;;
    --skip-build) skip_build=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; refuse "unknown argument $1" ;;
  esac
done

# Hard refusals before anything else runs (the test process repeats every check).
[ "$project" = 298161 ] || refuse "--project must be the sandbox project 298161"
[[ "$prefix" =~ ^[0-9a-f]{8}$ ]] && [ "$prefix" != 00000000 ] || refuse "--subject-prefix must be 8 lower-case hex digits"
[[ "$out" = /* ]] || refuse "--output-dir must be absolute"
[[ "$name" =~ ^[a-z0-9][a-z0-9-]{2,80}$ ]] || refuse "--report-name must be a lower-case file stem"
case "$late" in after-pass-1|after-request) ;; *) refuse "--late-capture must be after-pass-1 or after-request" ;; esac
for var in PLATFORM_ENVIRONMENT ENVIRONMENT APP_ENV VAPOR_ENV POSTHOG_MEASUREMENT_ENVIRONMENT; do
  case "$(printf '%s' "${!var:-}" | tr '[:upper:]' '[:lower:]')" in prod*) refuse "production configuration ($var)" ;; esac
done
for var in POSTHOG_ERASURE_API_KEY POSTHOG_PROJECT_API_KEY POSTHOG_API_KEY POSTHOG_PERSONAL_API_KEY; do
  [ -z "${!var:-}" ] || refuse "$var is set; keys come only from the private files"
done
if [ -n "${POSTHOG_ERASURE_PROJECT_ID:-}" ] && [ "$POSTHOG_ERASURE_PROJECT_ID" != 298161 ]; then
  refuse "POSTHOG_ERASURE_PROJECT_ID names a non-sandbox project"
fi

here="$(cd "$(dirname "$0")" && pwd)"; repo="$(cd "$here/.." && pwd)"
mkdir -p "$out"
if [ "$resume" = 0 ] && { [ -e "$out/$name-state.json" ] || [ -e "$out/$name-report.json" ]; }; then
  refuse "--report-name $name was already used in $out (pass --resume to continue that run)"
fi
work="$(mktemp -d "${TMPDIR:-/tmp}/posthog-l7.XXXXXX")"
fake_pid=""; container=""
cleanup() {
  if [ -n "$fake_pid" ]; then kill -TERM "$fake_pid" 2>/dev/null || true; wait "$fake_pid" 2>/dev/null || true; fi
  if [ -n "$container" ]; then docker rm -f "$container" >/dev/null 2>&1 || true; fi
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

case "$mode" in
  dry-run)
    [ -z "$approval" ] || refuse "--approval-ref is for live mode only"
    [ "$resume" = 0 ] || refuse "a dry run cannot resume: the fake PostHog keeps its state in memory (use --split-after-seconds)"
    if [ -z "$key_file" ] && [ -z "$capture_file" ]; then
      # Synthetic keys for the fake only: random, marked synthetic, no PostHog prefixes.
      key_file="$work/erasure-synthetic.json"; capture_file="$work/capture-synthetic.json"
      umask 077
      python3 -B -I - "$key_file" "$capture_file" <<'PY'
import json, secrets, sys
json.dump({"apiKey": "synthetic-l7-personal-key-" + secrets.token_hex(16), "host": "https://eu.posthog.com",
           "projectID": "298161", "purpose": "L7 dry run against the local fake only", "synthetic": True},
          open(sys.argv[1], "w"))
json.dump({"publicWriteToken": "synthetic-l7-project-token-" + secrets.token_hex(16), "host": "https://eu.i.posthog.com",
           "projectId": 298161, "environment": "sandbox", "synthetic": True}, open(sys.argv[2], "w"))
PY
    fi
    case "$key_file$capture_file" in *"/.config/snaglist/"*) refuse "a dry run never uses the real key files" ;; esac
    ;;
  live)
    [[ "$approval" =~ ^[A-Za-z0-9][A-Za-z0-9\ ._:#/-]{7,159}$ ]] || refuse "live mode needs --approval-ref (Dan's concrete approval reference)"
    [[ "$operator" =~ ^[a-z][a-z0-9._-]{1,63}$ ]] || refuse "live mode needs --operator <handle>"
    key_file="${key_file:-$HOME/.config/snaglist/measurement/posthog-erasure-sandbox.json}"
    capture_file="${capture_file:-$HOME/.config/snaglist/measurement/posthog-sandbox.json}"
    ;;
  *) refuse "--mode must be dry-run or live" ;;
esac
if [ -n "$split" ]; then
  [ "$mode" = dry-run ] || refuse "--split-after-seconds is for dry runs only"
  [[ "$split" =~ ^[0-9]+$ ]] && [ "$split" -ge 5 ] || refuse "--split-after-seconds must be a whole number >= 5"
fi

# Shape and privacy checks of both files, printing no value.
python3 -B -I - "$mode" "$key_file" "$capture_file" <<'PY' || exit 2
import json, os, stat, sys
mode, key_file, capture_file = sys.argv[1:4]
def fail(message):
    print("REFUSED: " + message, file=sys.stderr); sys.exit(2)
for path in (key_file, capture_file):
    if not os.path.isabs(path) or not os.path.isfile(path):
        fail(os.path.basename(path) + " is missing")
    if stat.S_IMODE(os.stat(path).st_mode) & 0o077:
        fail(os.path.basename(path) + " is not private (mode 0600)")
key = json.load(open(key_file, encoding="utf-8"))
cap = json.load(open(capture_file, encoding="utf-8"))
if key.get("host") != "https://eu.posthog.com" or str(key.get("projectID", key.get("projectId"))) != "298161":
    fail("the erasure key file is not the EU sandbox project 298161")
if cap.get("host") != "https://eu.i.posthog.com" or str(cap.get("projectId")) != "298161" or cap.get("environment") != "sandbox":
    fail("the capture configuration is not the EU sandbox project 298161")
synthetic = key.get("synthetic") is True and cap.get("synthetic") is True
if mode == "dry-run" and not synthetic:
    fail("a dry run needs synthetic key files")
if mode == "live" and (key.get("synthetic") or cap.get("synthetic")):
    fail("live mode needs the real sandbox files")
PY

# Database: an explicit loopback disposable one, or a throwaway container.
if [ -z "${DATABASE_URL:-}" ]; then
  [ "$resume" = 0 ] || refuse "--resume needs the DATABASE_URL of the paused run"
  container="snaglist-posthog-l7-$RANDOM"
  docker run --rm -d --name "$container" -e POSTGRES_USER=snaglist -e POSTGRES_PASSWORD=snaglist \
    -e POSTGRES_DB=snaglist_test -p 127.0.0.1::5432 postgres:16-alpine >/dev/null
  for _ in $(seq 1 80); do
    docker exec "$container" pg_isready -U snaglist -d snaglist_test >/dev/null 2>&1 && break
    sleep 0.25
  done
  port="$(docker port "$container" 5432/tcp | sed 's/.*://')"
  export DATABASE_URL="postgres://snaglist:snaglist@127.0.0.1:${port}/snaglist_test"
fi
export JWT_SECRET="${JWT_SECRET:-synthetic-posthog-l7-harness-signing-key}"

if [ "$mode" = dry-run ]; then
  ready="$work/fake.port"
  python3 -B -I "$here/posthog_l7_fake_server.py" --erasure-key-file "$key_file" --capture-config "$capture_file" \
    --ready-file "$ready" --request-log "$out/$name-fake-requests.jsonl" --state-out "$out/$name-fake-state.json" \
    --ingest-lag "$fake_lag" --person-removal-delay "$fake_removal" --deletion-delay "$fake_deletion" &
  fake_pid=$!
  for _ in $(seq 1 100); do [ -s "$ready" ] && break; sleep 0.1; done
  [ -s "$ready" ] || { echo "the fake PostHog did not start" >&2; exit 1; }
  export POSTHOG_L7_FAKE_BASE="http://127.0.0.1:$(cat "$ready")"
fi

head="$(git -C "$repo" rev-parse --short HEAD 2>/dev/null || echo unknown)"
[ -z "$(git -C "$repo" status --porcelain 2>/dev/null)" ] || head="$head-dirty"
export POSTHOG_L7_HARNESS=1 POSTHOG_L7_MODE="$mode" POSTHOG_L7_PROJECT_ID="$project" POSTHOG_L7_SUBJECT_PREFIX="$prefix" \
  POSTHOG_L7_ERASURE_KEY_FILE="$key_file" POSTHOG_L7_CAPTURE_CONFIG="$capture_file" POSTHOG_L7_OUTPUT_DIR="$out" \
  POSTHOG_L7_REPORT_NAME="$name" POSTHOG_L7_LATE_CAPTURE="$late" POSTHOG_L7_GIT_HEAD="$head" \
  POSTHOG_L7_RESUME="$resume"
[ -z "$approval" ] || export POSTHOG_L7_LIVE_APPROVAL="$approval"
[ -z "$operator" ] || export POSTHOG_L7_OPERATOR="$operator"
[ -z "$window" ] || export POSTHOG_L7_WINDOW_SECONDS="$window"
[ -z "$real_wait" ] || export POSTHOG_L7_REAL_WAIT_SECONDS="$real_wait"
[ -z "$poll" ] || export POSTHOG_L7_POLL_SECONDS="$poll"
[ -z "$max_run" ] || export POSTHOG_L7_MAX_RUN_SECONDS="$max_run"
[ -z "$max_deletion_wait" ] || export POSTHOG_L7_MAX_DELETION_WAIT_SECONDS="$max_deletion_wait"
[ -z "$ingest_timeout" ] || export POSTHOG_L7_INGEST_TIMEOUT_SECONDS="$ingest_timeout"

cd "$repo"
flags=(--build-system native --disable-sandbox --jobs 4 -Xswiftc -swift-version -Xswiftc 5)
[ "$skip_build" = 1 ] || swift build "${flags[@]}" --build-tests
run_test() {
  swift test "${flags[@]}" --skip-build --filter 'PostHogL7HarnessTests/testL7RealTransportErasureAcceptance' 2>&1 \
    | sed -E 's#postgres(ql)?://[^ ]*#postgres://<redacted>#g' | tee -a "$work/test.out"
  return ${PIPESTATUS[0]}
}
set +e
if [ -n "$split" ]; then
  echo "== invocation 1 (pauses after ${split} s)"
  POSTHOG_L7_MAX_RUN_SECONDS="$split" run_test
  first_exit=$?
  test_exit=$first_exit
  first_status="$(python3 -B -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$out/$name-report.json" 2>/dev/null)"
  echo "invocation 1: exit $first_exit, status ${first_status:-none}"
  if [ "$first_status" = waiting ]; then
    echo "== invocation 2 (resume: same database, same fake PostHog, saved state)"
    POSTHOG_L7_RESUME=1 run_test
    test_exit=$?
  fi
else
  run_test
  test_exit=$?
fi
set -e

report="$out/$name-report.json"
if [ -f "$report" ]; then
  python3 -B -I - "$report" <<'PY'
import json, sys
r = json.load(open(sys.argv[1], encoding="utf-8"))
print(f"L7 {r.get('mode')} status={r.get('status')} job={(r.get('job') or {}).get('state')} "
      f"reason={(r.get('job') or {}).get('lastErrorKind')} passes={len(r.get('passes') or [])}")
for e in r.get("expectations") or []:
    print(f"  {e['id']:>4} {'ok ' if e['matches'] else 'NO '} {e['description']}")
print("report:", sys.argv[1])
PY
  status="$(python3 -B -I -c 'import json,sys;print(json.load(open(sys.argv[1]))["status"])' "$report")"
  case "$status" in finished) [ "$test_exit" = 0 ] && exit 0 || exit 1 ;; waiting) exit 3 ;; *) exit 1 ;; esac
fi
# No report: the test process refused before any request, or failed to start.
grep -q "POSTHOG-L7 REFUSED" "$work/test.out" && exit 2
exit 1
