#!/usr/bin/env bash
# Behavioral test for bin/install-runner-up.sh.
#
# The oracle is the installer contract: install builds with VERSION taken
# from the clone's git describe and installs the result into the bin dir; it
# restarts the coordinator with launchctl kickstart -k only when the agent
# runs, never when it is idle or absent; a failed build installs and restarts
# nothing. --check changes nothing, reports a build that lags the clone, treats
# a missing setup file as the healthy idle state, and fails when a setup file
# exists but its check fails or no coordinator runs. make and launchctl are
# stubs and the clone is a sandbox git repo, so this runs on any CI host.
set -u
set +o pipefail

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && cd .. && pwd)"
script="$root/bin/install-runner-up.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/install-runner-up.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

fails=0
ok() { printf 'ok: %s\n' "$*"; }
bad() {
  printf 'FAIL: %s\n' "$*"
  fails=$((fails + 1))
}

stubs="$sandbox/stubs"
clone="$sandbox/runner-up"
bindir="$sandbox/bin"
setup="$sandbox/config.json"
calls="$sandbox/calls"
mkdir -p "$stubs" "$clone"

# make: records its arguments; "make build VERSION=v" writes a runner-up that
# prints v for `version` and exits $CHECK_EXIT for `check-config`.
cat >"$stubs/make" <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >>"$CALLS"
[ "${MAKE_EXIT:-0}" -eq 0 ] || exit "$MAKE_EXIT"
v=""
for a in "$@"; do case "$a" in VERSION=*) v=${a#VERSION=} ;; esac; done
cat >runner-up <<STUB
#!/usr/bin/env bash
case "\$1" in
  version) echo "$v" ;;
  check-config) echo "check-config said no" >&2; exit "\${CHECK_EXIT:-0}" ;;
esac
STUB
chmod +x runner-up
EOF
# launchctl: AGENT is absent, idle, or running (pid 4242).
cat >"$stubs/launchctl" <<'EOF'
#!/usr/bin/env bash
printf 'launchctl %s\n' "$*" >>"$CALLS"
case "$1" in
  print)
    case "$AGENT" in
      absent) exit 113 ;;
      idle) printf 'gui/501/org.nix-community.home.runner-up = {\n\tstate = not running\n}\n' ;;
      running) printf 'gui/501/org.nix-community.home.runner-up = {\n\tstate = running\n\tpid = 4242\n}\n' ;;
    esac
    exit 0
    ;;
  kickstart) exit "${KICK_EXIT:-0}" ;;
esac
exit 1
EOF
chmod +x "$stubs/make" "$stubs/launchctl"

# The host's git config may force signing; the sandbox repo must not depend on it.
g() { git -C "$clone" -c user.name=t -c user.email=t@example.invalid -c commit.gpgSign=false -c tag.gpgSign=false "$@"; }
g init -q
g commit -q --allow-empty -m init
g tag -a v0.1.12 -m v0.1.12

# run MODE: runs the script against the sandbox; sets out and status.
run() {
  : >"$calls"
  out=$(cd "$clone" && env PATH="$stubs:$PATH" CALLS="$calls" \
    RUNNER_UP_CLONE="$clone" RUNNER_UP_BIN_DIR="$bindir" RUNNER_UP_SETUP="$setup" \
    "$script" "$@" 2>&1)
  status=$?
}
called() { grep -q -- "$1" "$calls"; }

# 1. Install with a running coordinator: build pinned to git describe,
#    installed, then restarted.
AGENT=running
export AGENT
run
if [ "$status" -eq 0 ] && called 'make build VERSION=v0.1.12' \
  && [ "$("$bindir/runner-up" version)" = v0.1.12 ] && called 'launchctl kickstart -k gui/'; then
  ok "install builds from git describe, installs, and restarts a running coordinator"
else
  bad "install with a running coordinator (status $status): $out"
fi

# 2. Install with an idle agent (no setup): no restart.
AGENT=idle
run
if [ "$status" -eq 0 ] && ! called kickstart && printf '%s' "$out" | grep -q 'idle'; then
  ok "install leaves an idle agent alone"
else
  bad "install with an idle agent (status $status): $out"
fi

# 3. Install with no agent and a setup file: warns, does not restart.
AGENT=absent
echo '{}' >"$setup"
run
if [ "$status" -eq 0 ] && ! called kickstart && printf '%s' "$out" | grep -q '^warn .*not loaded'; then
  ok "install warns when a setup exists but the agent is not loaded"
else
  bad "install with no agent and a setup (status $status): $out"
fi

# 3b. Install with a loaded but stopped agent and a setup file: warns, does not restart.
AGENT=idle
run
if [ "$status" -eq 0 ] && ! called kickstart && printf '%s' "$out" | grep -q '^warn .*not running although the setup exists'; then
  ok "install warns when a setup exists but the loaded agent is not running"
else
  bad "install with a stopped agent and a setup (status $status): $out"
fi
rm -f "$setup"

# 4. A failed build installs and restarts nothing.
AGENT=running
rm -f "$bindir/runner-up" "$clone/runner-up"
MAKE_EXIT=2 run
if [ "$status" -eq 1 ] && [ ! -e "$bindir/runner-up" ] && ! called kickstart; then
  ok "a failed build installs and restarts nothing"
else
  bad "failed build (status $status): $out"
fi
unset MAKE_EXIT
run # reinstall for the --check cases

# 5. A failed restart is a FAIL.
KICK_EXIT=1 run
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL .*kickstart'; then
  ok "a failed restart fails the install"
else
  bad "failed restart (status $status): $out"
fi

# 6. --check with no setup: healthy idle, changes nothing.
AGENT=idle
run --check
if [ "$status" -eq 0 ] && ! called make && ! called kickstart \
  && printf '%s' "$out" | grep -q 'no setup file'; then
  ok "--check treats no setup as healthy and changes nothing"
else
  bad "--check without a setup (status $status): $out"
fi

# 7. --check with a setup, a passing check, and a running coordinator.
echo '{}' >"$setup"
AGENT=running
run --check
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q 'coordinator running (pid 4242)'; then
  ok "--check passes a valid setup with a running coordinator"
else
  bad "--check healthy coordinator (status $status): $out"
fi

# 8. --check with a setup but an idle agent fails.
AGENT=idle
run --check
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL .*not running'; then
  ok "--check fails when a setup exists but no coordinator runs"
else
  bad "--check idle with a setup (status $status): $out"
fi

# 9. --check with a setup that fails check-config.
AGENT=running
CHECK_EXIT=2 run --check
if [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q '^FAIL .*check-config said no'; then
  ok "--check fails a setup that check-config refuses, with its reason"
else
  bad "--check refused setup (status $status): $out"
fi

# 10. --check warns when the installed build lags the clone.
g commit -q --allow-empty -m next
g tag -a v0.1.13 -m v0.1.13
run --check
if [ "$status" -eq 0 ] && printf '%s' "$out" | grep -q '^warn .*v0.1.12 but the clone is at v0.1.13'; then
  ok "--check warns when the installed build lags the clone"
else
  bad "--check stale build (status $status): $out"
fi

# 11. An unknown argument is a usage error.
run --bogus
if [ "$status" -eq 2 ]; then
  ok "an unknown argument exits 2"
else
  bad "unknown argument (status $status): $out"
fi

if [ "$fails" -eq 0 ]; then
  echo "install_runner_up_test: all checks passed"
else
  echo "install_runner_up_test: $fails check(s) failed"
  exit 1
fi
