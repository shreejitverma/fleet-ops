#!/usr/bin/env bash
# install-runner-up.sh: build the runner-up fork into ~/go/bin and keep the
# coordinator LaunchAgent on that build; with --check, verify without changing
# anything.
#
# The coordinator (launchd agent org.nix-community.home.runner-up, defined in
# dotfiles-nix nix/home/darwin.nix) runs ~/go/bin/runner-up serve and is kept
# alive only while the setup file exists. A rebuild replaces the binary on
# disk but not the running process, so after installing, a running
# coordinator is restarted onto the new build. That is safe mid-job: the
# agent sets AbandonProcessGroup, so each running job's place runner keeps its
# place and runs to its end while the coordinator restarts (upstream README,
# "Running as a service").
#
# Usage:
#   install-runner-up.sh          build, install, restart a running coordinator (manifest install)
#   install-runner-up.sh --check  verify only, changes nothing (doctor.sh)
# Prints one "ok"/"warn"/"FAIL" line per check and exits 1 on any FAIL.
set -uo pipefail

CLONE="${RUNNER_UP_CLONE:-$HOME/github/runner-up}"
BIN_DIR="${RUNNER_UP_BIN_DIR:-$HOME/go/bin}"
SETUP="${RUNNER_UP_SETUP:-$HOME/Library/Application Support/runner-up/config.json}"
LABEL="org.nix-community.home.runner-up"
SERVICE="gui/$(id -u)/$LABEL"
BIN="$BIN_DIR/runner-up"

mode=install
case "${1:-}" in
  "") ;;
  --check) mode=check ;;
  *)
    echo "usage: $0 [--check]" >&2
    exit 2
    ;;
esac

fail=0
ok() { printf 'ok    %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*"; }
bad() {
  printf 'FAIL  %s\n' "$*"
  fail=1
}

# The coordinator's pid, or nothing when the agent is not loaded or is loaded
# but idle (no setup file, so launchd keeps it stopped).
coordinator_pid() {
  launchctl print "$SERVICE" 2>/dev/null | awk '$1 == "pid" && $2 == "=" {print $3; exit}'
}
agent_loaded() { launchctl print "$SERVICE" >/dev/null 2>&1; }

want=$(git -C "$CLONE" describe --tags --always 2>/dev/null)
if [ -z "$want" ]; then
  bad "cannot describe the runner-up clone at $CLONE"
  exit 1
fi

if [ "$mode" = install ]; then
  if ! (cd "$CLONE" && make build VERSION="$want"); then
    bad "make build failed in $CLONE"
    exit 1
  fi
  if ! { install -d "$BIN_DIR" && install -m 755 "$CLONE/runner-up" "$BIN"; }; then
    bad "could not install runner-up into $BIN_DIR"
    exit 1
  fi
  ok "installed runner-up $want at $BIN"
  pid=$(coordinator_pid)
  if [ -n "$pid" ]; then
    if launchctl kickstart -k "$SERVICE"; then
      ok "restarted the coordinator (was pid $pid) onto $want; running jobs carry on"
    else
      bad "launchctl kickstart -k $SERVICE failed; the coordinator still runs the old build"
    fi
  elif agent_loaded; then
    if [ -f "$SETUP" ]; then
      warn "coordinator agent loaded but not running although the setup exists (see ~/Library/Logs/runner-up.log)"
    else
      ok "coordinator agent loaded and idle (no setup file), nothing to restart"
    fi
  elif [ -f "$SETUP" ]; then
    warn "a setup file exists but the coordinator agent is not loaded (rebuild dotfiles-nix)"
  fi
  exit "$fail"
fi

# --check
have=$("$BIN" version 2>/dev/null)
if [ -z "$have" ]; then
  bad "runner-up missing or broken at $BIN (run: $0)"
elif [ "$have" != "$want" ]; then
  warn "installed runner-up is $have but the clone is at $want (run: $0)"
else
  ok "runner-up $have installed from the clone"
fi

if [ ! -f "$SETUP" ]; then
  ok "no setup file: no coordinator runs, by design"
  exit "$fail"
fi

if out=$("$BIN" check-config --config "$SETUP" 2>&1); then
  ok "setup passes check-config"
else
  bad "setup fails check-config: $(printf '%s' "$out" | head -1)"
fi

pid=$(coordinator_pid)
if [ -n "$pid" ]; then
  ok "coordinator running (pid $pid)"
elif agent_loaded; then
  bad "coordinator agent loaded but not running although the setup exists (see ~/Library/Logs/runner-up.log)"
else
  bad "a setup file exists but the coordinator agent is not loaded (rebuild dotfiles-nix)"
fi
exit "$fail"
