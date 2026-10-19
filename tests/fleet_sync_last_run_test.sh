#!/usr/bin/env bash
# Behavioral test for bin/fleet-sync-last-run.sh.
#
# The oracle is the doctor contract for the server-side layer: a successful
# last run is ok, a failed or timed-out one is a FAIL that names every repo
# the run could not sync (with the token hint only on an HTTP 403), a run
# that never started is a FAIL without a log parse, a cancelled or stale run
# is a warn, and being unable to ask GitHub is a warn, never a FAIL. The failed-run log
# fixture is the real --log-failed output of fleet-sync run 39195933519
# (2026-10-18), so a parser that only matches an idealised format is
# rejected. The stub gh returns what `gh run list --jq` would emit; the jq
# expression itself is exercised against GitHub, not here.
set -u
set +o pipefail

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && cd .. && pwd)"
script="$root/bin/fleet-sync-last-run.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/fleet-sync-last-run.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

fails=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }

url="https://github.com/shreejitverma/fleet-ops/actions/runs/39195933519"
step=$'sync\tFast-forward every fork\'s default branch from upstream\t'
{
  printf '%s2026-10-19T03:42:33.4573224Z retry     acp-mock: HTTP 403: Resource not accessible by personal access token (https://api.github.com/repos/shreejitverma/acp-mock/merge-upstream)\n' "$step"
  printf '%s2026-10-19T03:42:39.0422573Z FAILED    acp-mock: HTTP 403: Resource not accessible by personal access token (https://api.github.com/repos/shreejitverma/acp-mock/merge-upstream)\n' "$step"
  printf '%s2026-10-19T03:42:45.2538710Z FAILED    gnhf: HTTP 502: Bad Gateway\n' "$step"
  printf '%s2026-10-19T03:42:51.3920799Z ##[error]Process completed with exit code 1.\n' "$step"
} >"$sandbox/failed.log"

# LIST_OUT: what `gh run list` prints; LIST_STATUS: its exit status.
# VIEW_LOG: the file `gh run view --log-failed` prints (empty = unreadable).
cat >"$sandbox/gh" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "run list")
    case " $* " in
      *" --status completed "*) ;;
      *) printf '1\tfailure\t60\thttps://example.invalid/in-progress-masks-verdict\n'; exit 0 ;;
    esac
    if [ "${LIST_STATUS:-0}" -ne 0 ]; then
      echo "HTTP 401: Bad credentials" >&2
      exit "$LIST_STATUS"
    fi
    printf '%s\n' "$LIST_OUT"
    ;;
  "run view")
    [ -n "${VIEW_LOG:-}" ] && cat "$VIEW_LOG"
    exit 0
    ;;
  *) echo "unexpected gh $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$sandbox/gh"

run() {
  PATH="$sandbox:$PATH" bash "$script" >"$sandbox/out" 2>"$sandbox/err"
  status=$?
}

LIST_OUT=$'39195962900\tsuccess\t14400\thttps://example.invalid/ok' run
[ "$status" -eq 0 ] && ok "success exits 0" || bad "success exits 0 (got $status)"
grep -q '^ok    last server-side fleet-sync run succeeded 4h ago$' "$sandbox/out" \
  && ok "success reported with age" || bad "success reported with age: $(cat "$sandbox/out")"
grep -q '^\(warn\|FAIL\)' "$sandbox/out" && bad "fresh success has no warn or FAIL" || ok "fresh success has no warn or FAIL"

LIST_OUT=$'39195933519\tfailure\t3600\t'"$url" VIEW_LOG="$sandbox/failed.log" run
[ "$status" -eq 1 ] && ok "failed run exits 1" || bad "failed run exits 1 (got $status)"
grep -q "^FAIL  last server-side fleet-sync run ended 'failure' 1h ago: $url\$" "$sandbox/out" \
  && ok "failed run names its URL" || bad "failed run names its URL"
grep -q '^FAIL  server-side sync: acp-mock: HTTP 403: .*(add the repo to the FLEET_SYNC_TOKEN repository list; see README)$' "$sandbox/out" \
  && ok "403 repo named with token hint" || bad "403 repo named with token hint"
grep -q '^FAIL  server-side sync: gnhf: HTTP 502: Bad Gateway$' "$sandbox/out" \
  && ok "non-403 repo named without token hint" || bad "non-403 repo named without token hint"
[ "$(grep -c 'acp-mock' "$sandbox/out")" -eq 1 ] && ok "retry line not reported as a failure" || bad "retry line not reported as a failure"

LIST_OUT=$'39195933519\tfailure\t3600\t'"$url" VIEW_LOG="" run
[ "$status" -eq 1 ] && ok "failed run with unreadable log still exits 1" || bad "failed run with unreadable log still exits 1 (got $status)"
grep -q '^warn  could not list the failed repos; read: gh run view 39195933519 ' "$sandbox/out" \
  && ok "unreadable log points at the manual command" || bad "unreadable log points at the manual command"

LIST_OUT=$'2\ttimed_out\t7200\t'"$url" VIEW_LOG="$sandbox/failed.log" run
[ "$status" -eq 1 ] && ok "timed-out run exits 1" || bad "timed-out run exits 1 (got $status)"
grep -q "^FAIL  last server-side fleet-sync run ended 'timed_out' 2h ago: $url\$" "$sandbox/out" \
  && ok "timed-out run names its URL" || bad "timed-out run names its URL"
grep -q '^FAIL  server-side sync: gnhf: HTTP 502: Bad Gateway$' "$sandbox/out" \
  && ok "timed-out run names its failed repos" || bad "timed-out run names its failed repos"

LIST_OUT=$'3\tstartup_failure\t3600\t'"$url" VIEW_LOG="$sandbox/failed.log" run
[ "$status" -eq 1 ] && ok "startup failure exits 1" || bad "startup failure exits 1 (got $status)"
grep -q "^FAIL  last server-side fleet-sync run did not start 1h ago (is fleet-sync.yml valid?): $url\$" "$sandbox/out" \
  && ok "startup failure says the workflow did not start" || bad "startup failure says the workflow did not start: $(cat "$sandbox/out")"
grep -q 'server-side sync:' "$sandbox/out" && bad "startup failure does not parse the log" || ok "startup failure does not parse the log"

LIST_OUT=$'39050533541\tsuccess\t200000\thttps://example.invalid/old' run
[ "$status" -eq 0 ] && ok "stale success exits 0" || bad "stale success exits 0 (got $status)"
grep -q '^warn  no fleet-sync run has completed for 55h; the daily schedule may have stopped' "$sandbox/out" \
  && ok "stale run warned" || bad "stale run warned"

LIST_OUT=$'1\tcancelled\t100\thttps://example.invalid/c' run
[ "$status" -eq 0 ] && ok "cancelled run exits 0" || bad "cancelled run exits 0 (got $status)"
grep -q "^warn  last server-side fleet-sync run ended 'cancelled'" "$sandbox/out" \
  && ok "cancelled run warned" || bad "cancelled run warned"

LIST_OUT=none run
[ "$status" -eq 0 ] && ok "no runs exits 0" || bad "no runs exits 0 (got $status)"
grep -q '^warn  no completed fleet-sync run' "$sandbox/out" && ok "no runs warned" || bad "no runs warned"

LIST_OUT="" LIST_STATUS=1 run
[ "$status" -eq 0 ] && ok "unreachable GitHub exits 0" || bad "unreachable GitHub exits 0 (got $status)"
grep -q '^warn  could not read fleet-sync runs from shreejitverma/fleet-ops: HTTP 401: Bad credentials' "$sandbox/out" \
  && ok "unreachable GitHub warns with the real error" || bad "unreachable GitHub warns with the real error"

if [ "$fails" -eq 0 ]; then
  echo "fleet_sync_last_run_test: ALL PASS"
else
  echo "fleet_sync_last_run_test: $fails FAILURE(S)"
  exit 1
fi
