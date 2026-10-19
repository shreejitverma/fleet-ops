#!/usr/bin/env bash
# fleet-sync-last-run.sh: report the last completed server-side fleet-sync
# run, so a fork the workflow cannot reach shows up in doctor.sh instead of
# only in the Actions tab.
#
# FLEET_SYNC_TOKEN is a fine-grained PAT with a per-repo list. A fork the
# list omits fails merge-upstream with HTTP 403 and turns every daily run
# red, while the local sync layer keeps that fork current, so nothing on
# this machine noticed (found 2026-10-18: archify, acp-mock, pi-launcher).
#
# Reads shreejitverma/fleet-ops. A run that ended failure, timed_out or
# startup_failure is a FAIL; any other non-success conclusion is a warn.
# Prints one "ok"/"warn"/"FAIL" line per finding, one FAIL per repo the run
# could not sync, and exits 1 on any FAIL. Not being able to ask GitHub (gh
# missing, offline, unauthenticated) is a warn, never a FAIL, so doctor.sh
# stays usable offline.
set -uo pipefail

REPO="shreejitverma/fleet-ops"
WORKFLOW="fleet-sync.yml"
# The schedule is daily, so two days without a completed run means it
# stopped firing.
STALE_AFTER=$((48 * 3600))

fail=0
ok() { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fail=1
}

if ! command -v gh >/dev/null 2>&1; then
  warn "gh not on PATH; server-side fleet-sync status unknown"
  exit 0
fi

errf="$(mktemp "${TMPDIR:-/tmp}/fleet-sync-last-run.XXXXXX")"
trap 'rm -f "$errf"' EXIT

# --status completed: a run still in progress must not hide the verdict of
# the last finished one.
if ! line=$(gh run list -R "$REPO" --workflow "$WORKFLOW" --status completed -L 1 \
  --json databaseId,conclusion,createdAt,url \
  --jq 'if length == 0 then "none" else .[0] | [.databaseId, .conclusion, ((now - (.createdAt | fromdateiso8601)) | floor), .url] | @tsv end' \
  2>"$errf"); then
  warn "could not read fleet-sync runs from $REPO: $(tr '\n' ' ' <"$errf")"
  exit 0
fi

if [ "$line" = "none" ]; then
  warn "no completed fleet-sync run in $REPO yet"
  exit 0
fi

IFS=$'\t' read -r id conclusion age url <<<"$line"
hours=$((age / 3600))

case "$conclusion" in
  success)
    ok "last server-side fleet-sync run succeeded ${hours}h ago"
    ;;
  startup_failure)
    bad "last server-side fleet-sync run did not start ${hours}h ago (is fleet-sync.yml valid?): $url"
    ;;
  failure | timed_out)
    bad "last server-side fleet-sync run ended '$conclusion' ${hours}h ago: $url"
    # bin/fleet-sync-remote.sh prints "FAILED    <repo>: <error>" for each
    # repo it gave up on.
    failed=$(gh run view "$id" -R "$REPO" --log-failed 2>/dev/null | sed -n 's/.*FAILED    //p')
    if [ -z "$failed" ]; then
      warn "could not list the failed repos; read: gh run view $id -R $REPO --log-failed"
    fi
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      case "$f" in
        *"HTTP 403"*) bad "server-side sync: $f (add the repo to the FLEET_SYNC_TOKEN repository list; see README)" ;;
        *) bad "server-side sync: $f" ;;
      esac
    done <<<"$failed"
    ;;
  *)
    warn "last server-side fleet-sync run ended '$conclusion' ${hours}h ago: $url"
    ;;
esac

if [ "$age" -gt "$STALE_AFTER" ]; then
  warn "no fleet-sync run has completed for ${hours}h; the daily schedule may have stopped: $url"
fi

exit "$fail"
