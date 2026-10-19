#!/usr/bin/env bash
# Behavioral test for bin/install-pi-launcher.sh.
#
# The oracle is the installer contract: --check never mutates, a cask older
# than the fork's pinned release fails (version order, not string order), a
# stale tap is refreshed once before failing, a missing cask is installed,
# and a wrong signing team or a bundled Pi that differs from the pin fails.
# brew, codesign and spctl are stubs, so this runs on any CI host.
set -u
set +o pipefail

root="$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && cd .. && pwd)"
script="$root/bin/install-pi-launcher.sh"
sandbox="$(mktemp -d "${TMPDIR:-/tmp}/install-pi-launcher.XXXXXX")"
trap 'rm -rf "$sandbox"' EXIT

fails=0
ok() { printf 'ok: %s\n' "$*"; }
bad() { printf 'FAIL: %s\n' "$*"; fails=$((fails + 1)); }

stubs="$sandbox/stubs"
app="$sandbox/Applications/Pi Launcher.app"
clone="$sandbox/pi-launcher"
mkdir -p "$stubs" "$app/Contents/MacOS" "$clone/packaging"

# brew: INSTALLED holds the installed cask version (empty file = absent); the
# tap offers TAP_VERSION, and TAP_AFTER_UPDATE once `brew update` has run.
cat >"$stubs/brew" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$CALLS"
case "$1" in
  list) [ -s "$INSTALLED" ] && echo "pi-launcher $(cat "$INSTALLED")"; exit 0 ;;
  install | upgrade) cat "$TAP" >"$INSTALLED"; exit 0 ;;
  update) [ -n "${TAP_AFTER_UPDATE:-}" ] && echo "$TAP_AFTER_UPDATE" >"$TAP"; exit 0 ;;
esac
exit 1
EOF
cat >"$stubs/codesign" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --verify) exit 0 ;;
  -dv) printf 'Identifier=com.kunchenguid.pi-launcher\nTeamIdentifier=%s\n' "$TEAM" >&2; exit 0 ;;
esac
exit 1
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$stubs/spctl"
# shellcheck disable=SC2016 # expands when the stub runs, not here
printf '#!/usr/bin/env bash\necho "$BUNDLED_PI"\n' >"$app/Contents/MacOS/pi-launcher"
chmod +x "$stubs/brew" "$stubs/codesign" "$stubs/spctl" "$app/Contents/MacOS/pi-launcher"
ln -s "$app/Contents/MacOS/pi-launcher" "$stubs/pi-signed"
printf '{\n  "version": "1.3.0"\n}\n' >"$clone/packaging/pi-release.json"

calls="$sandbox/calls"
installed="$sandbox/installed"
tap="$sandbox/tap"

# run <fork version> <installed or ""> <tap version> [script args...]
run() {
  printf '{\n  ".": "%s"\n}\n' "$1" >"$clone/.release-please-manifest.json"
  printf '%s' "$2" >"$installed"
  echo "$3" >"$tap"
  shift 3
  : >"$calls"
  PATH="$stubs:$PATH" CALLS="$calls" INSTALLED="$installed" TAP="$tap" \
    TEAM="${TEAM:-9T2J7MNUP9}" BUNDLED_PI="${BUNDLED_PI:-1.3.0}" \
    TAP_AFTER_UPDATE="${TAP_AFTER_UPDATE:-}" PI_LAUNCHER_CLONE="$clone" \
    bash "$script" "$@" >"$sandbox/out" 2>&1
}

# expect <description> <command...>: the command must succeed.
expect() {
  local d="$1"
  shift
  if "$@"; then ok "$d"; else bad "$d: $(cat "$sandbox/out")"; fi
}
calls_only_list() { ! grep -qv '^list' "$calls"; }
upgrade_count() { [ "$(grep -c '^upgrade' "$calls")" -eq "$1" ]; }

run 1.2.17 1.2.17 1.2.17 --check
expect "check passes on a matching signed install" [ $? -eq 0 ]
expect "check is read-only" calls_only_list

run 1.2.10 1.2.9 1.2.9 --check
expect "check fails when the cask is older (1.2.9 < 1.2.10)" [ $? -eq 1 ]
expect "older cask is named" grep -q '^FAIL  cask pi-launcher 1.2.9 is older' "$sandbox/out"

run 1.2.17 1.2.18 1.2.18 --check
expect "a newer cask than the fork passes" [ $? -eq 0 ]

TAP_AFTER_UPDATE=1.2.17 run 1.2.17 1.2.16 1.2.16
expect "stale tap is refreshed and the upgrade retried" [ $? -eq 0 ]
expect "taps refreshed once" grep -q '^update' "$calls"
expect "upgrade retried after the refresh" upgrade_count 2

run 1.2.17 1.2.16 1.2.16
expect "a tap still stale after refresh fails" [ $? -eq 1 ]

run 1.2.17 "" 1.2.17
expect "missing cask install succeeds" [ $? -eq 0 ]
expect "missing cask is installed from kunchenguid/tap" grep -q '^install --cask kunchenguid/tap/pi-launcher' "$calls"

TEAM=ABCDE12345 run 1.2.17 1.2.17 1.2.17 --check
expect "wrong signing team exits 1" [ $? -eq 1 ]
expect "wrong signing team is named" grep -q '^FAIL  not signed by Team 9T2J7MNUP9' "$sandbox/out"

BUNDLED_PI=1.2.0 run 1.2.17 1.2.17 1.2.17 --check
expect "bundled Pi differing from the pin exits 1" [ $? -eq 1 ]
expect "bundled Pi mismatch is named" grep -q '^FAIL  bundled Pi is 1.2.0' "$sandbox/out"

run 1.2.17 1.2.17 1.2.17 --bogus
expect "unknown argument exits 2" [ $? -eq 2 ]

if [ "$fails" -eq 0 ]; then
  echo "install_pi_launcher_test: ALL PASS"
else
  echo "install_pi_launcher_test: $fails FAILURE(S)"
  exit 1
fi
