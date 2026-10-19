#!/usr/bin/env bash
# Behavioral test for bin/fleet-sync-remote.sh.
#
# The oracle is the server-sync contract: a fast-forwardable fork is ok, a
# diverged fork is reported and does not fail the run, a transient failure is
# retried once, and a hard failure is printed and does not stop the loop.
# The script is invoked as `bash -e`, which is how GitHub Actions runs a step
# body. A wrong implementation that lets `set -e` abort inside `out=$(gh ...)`
# exits before the later repos and before any FAILED line.
set -u
set +o pipefail

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && cd .. && pwd)"
script="$root/bin/fleet-sync-remote.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/fleet-sync-remote.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

fails=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }
# check <description> <command...>: the command must succeed.
check() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}

cat >"$sandbox/gh" <<'EOF'
#!/usr/bin/env bash
name="${3#shreejitverma/}"
printf '%s\n' "$name" >>"$CALLS"
case "$name" in
  ok-repo) exit 0 ;;
  diverged-repo)
    echo "can't sync because there are diverging changes"
    exit 1
    ;;
  flaky-repo)
    n=0
    [ -f "$COUNT" ] && n=$(cat "$COUNT")
    echo $((n + 1)) >"$COUNT"
    if [ "$n" -eq 0 ]; then
      echo "HTTP 502"
      exit 1
    fi
    exit 0
    ;;
  denied-repo)
    echo "HTTP 404: Not Found (https://api.github.com/repos/shreejitverma/denied-repo)"
    exit 1
    ;;
  *)
    echo "unexpected repo $name"
    exit 1
    ;;
esac
EOF
cat >"$sandbox/sleep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SLEPT"
exit 0
EOF
chmod +x "$sandbox/gh" "$sandbox/sleep"

printf '%s\n' ok-repo diverged-repo flaky-repo denied-repo >"$sandbox/repos.txt"
calls="$sandbox/calls"
: >"$calls"
count="$sandbox/count"
slept="$sandbox/slept"
: >"$slept"

set +e
PATH="$sandbox:$PATH" CALLS="$calls" COUNT="$count" SLEPT="$slept" \
  bash -e "$script" "$sandbox/repos.txt" >"$sandbox/out" 2>"$sandbox/err"
status=$?
set -e

check "mixed run exits 1 (got $status)" [ "$status" -eq 1 ]
check "ok repo recorded" grep -q '^ok        ok-repo:' "$sandbox/out"
check "diverged repo recorded" grep -q '^diverged  diverged-repo' "$sandbox/out"
check "transient failure retried" grep -q '^retry     flaky-repo: HTTP 502' "$sandbox/out"
check "flaky repo recovered" grep -q '^ok        flaky-repo:' "$sandbox/out"
check "hard failure printed" grep -q '^FAILED    denied-repo: HTTP 404' "$sandbox/out"
# Order: denied is last, so a set -e abort would omit its FAILED line. The
# assertion above already requires that line. Also require every repo was
# attempted the expected number of times.
check "ok repo synced once" [ "$(grep -c '^ok-repo$' "$calls")" -eq 1 ]
check "diverged repo not retried" [ "$(grep -c '^diverged-repo$' "$calls")" -eq 1 ]
check "flaky repo attempted twice" [ "$(grep -c '^flaky-repo$' "$calls")" -eq 2 ]
check "denied repo attempted twice" [ "$(grep -c '^denied-repo$' "$calls")" -eq 2 ]
check "retry pauses 5 seconds" grep -q '^5$' "$slept"

printf '%s\n' ok-repo >"$sandbox/repos-ok.txt"
: >"$calls"
set +e
PATH="$sandbox:$PATH" CALLS="$calls" COUNT="$count" SLEPT="$slept" \
  bash -e "$script" "$sandbox/repos-ok.txt" >"$sandbox/out-ok" 2>"$sandbox/err-ok"
status=$?
set -e
check "all-ok run exits 0 (got $status)" [ "$status" -eq 0 ]

if [ "$fails" -eq 0 ]; then
  echo "fleet_sync_remote_test: ALL PASS"
else
  echo "fleet_sync_remote_test: $fails FAILURE(S)"
  exit 1
fi
