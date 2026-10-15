#!/usr/bin/env bash
# Fast-forward every fork named in repos.txt from its parent, server-side.
#
# Diverged forks are left untouched and do not fail the run. Any other
# non-zero gh repo sync is retried once, then recorded, and the loop
# continues so one repo cannot hide the rest.
#
# GitHub Actions runs a step body with `bash -e`. Under bash -e a failing
# command substitution aborts the shell before $? is captured. From
# 2026-09-22 through 2026-10-15 that dropped the real gh error and skipped
# every later repo, and the scheduled run exited 1 with no FAILED line.
# set +e is required even when this file is invoked as `bash -e`.
set -u
set +e

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && cd .. && pwd)"
repos_file="${1:-$root/repos.txt}"
if [ ! -f "$repos_file" ]; then
  echo "FAILED    repos file missing: $repos_file" >&2
  exit 1
fi

fail=0
while IFS= read -r repo || [ -n "$repo" ]; do
  [ -z "$repo" ] && continue
  case "$repo" in
    \#*) continue ;;
  esac
  attempt=0
  status=1
  out=""
  while [ "$attempt" -lt 2 ]; do
    attempt=$((attempt + 1))
    out=$(gh repo sync "shreejitverma/$repo" 2>&1)
    status=$?
    if [ "$status" -eq 0 ]; then
      break
    fi
    if printf '%s\n' "$out" | grep -qi "diverg"; then
      break
    fi
    if [ "$attempt" -lt 2 ]; then
      echo "retry     $repo: $out"
      sleep 5
    fi
  done
  if [ "$status" -eq 0 ]; then
    echo "ok        $repo: $out"
  elif printf '%s\n' "$out" | grep -qi "diverg"; then
    echo "diverged  $repo (left untouched)"
  else
    echo "FAILED    $repo: $out"
    fail=1
  fi
done < "$repos_file"
exit "$fail"
