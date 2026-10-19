#!/usr/bin/env bash
# Behavioral test for bin/install-pi-launcher.sh.
#
# The oracle is the installer contract: --check never mutates, a cask older
# than the fork's pinned release fails (version order, not string order), a
# stale tap is refreshed once before failing, a missing cask is installed,
# a missing or misplaced pi-signed link, an invalid signature, a wrong team or
# bundle id, and a Gatekeeper rejection each fail, and a cask at exactly the
# fork's release must bundle the Pi pinned at its release tag v<version>
# (the pin on HEAD can run ahead of the release; a missing tag only warns).
# brew, codesign and spctl are stubs and the clone is a sandbox git repo, so
# this runs on any CI host.
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
# codesign: VERIFY_EXIT is the --verify status; -dv reports BUNDLE and TEAM.
cat >"$stubs/codesign" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  --verify) exit "$VERIFY_EXIT" ;;
  -dv) printf 'Identifier=%s\nTeamIdentifier=%s\n' "$BUNDLE" "$TEAM" >&2; exit 0 ;;
esac
exit 1
EOF
# shellcheck disable=SC2016 # expands when the stub runs, not here
printf '#!/usr/bin/env bash\nexit "$SPCTL_EXIT"\n' >"$stubs/spctl"
# shellcheck disable=SC2016 # expands when the stub runs, not here
printf '#!/usr/bin/env bash\necho "$BUNDLED_PI"\nexit "$PI_EXIT"\n' >"$app/Contents/MacOS/pi-launcher"
mkdir -p "$sandbox/elsewhere"
cp "$app/Contents/MacOS/pi-launcher" "$sandbox/elsewhere/pi-launcher"
chmod +x "$stubs/brew" "$stubs/codesign" "$stubs/spctl" "$app/Contents/MacOS/pi-launcher" \
  "$sandbox/elsewhere/pi-launcher"
ln -s "$app/Contents/MacOS/pi-launcher" "$stubs/pi-signed"

# The host PATH minus any directory holding a real pi-signed, so the stub
# link (or its absence) is the only pi-signed the script can find.
host_path=""
IFS=: read -ra dirs <<<"$PATH"
for d in "${dirs[@]}"; do
  [ -e "$d/pi-signed" ] || host_path="$host_path:$d"
done

# The clone: release 1.2.17 is tagged v1.2.17 and pins Pi 1.3.0.
g() {
  git -C "$clone" -c user.name=test -c user.email=test@example.com \
    -c commit.gpgsign=false -c tag.gpgsign=false "$@" >/dev/null
}
# commit_pin <fork version> <Pi version> <message>
commit_pin() {
  printf '{\n  ".": "%s"\n}\n' "$1" >"$clone/.release-please-manifest.json"
  printf '{\n  "version": "%s"\n}\n' "$2" >"$clone/packaging/pi-release.json"
  g add -A && g commit -q -m "$3"
}
git init -q "$clone"
commit_pin 1.2.17 1.3.0 "chore(main): release 1.2.17"
g tag v1.2.17

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
  PATH="$stubs$host_path" CALLS="$calls" INSTALLED="$installed" TAP="$tap" \
    TEAM="${TEAM:-9T2J7MNUP9}" BUNDLE="${BUNDLE:-com.kunchenguid.pi-launcher}" \
    VERIFY_EXIT="${VERIFY_EXIT:-0}" SPCTL_EXIT="${SPCTL_EXIT:-0}" \
    BUNDLED_PI="${BUNDLED_PI:-1.3.0}" PI_EXIT="${PI_EXIT:-0}" \
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

BUNDLED_PI=1.4.0 run 1.2.17 1.2.18 1.2.18 --check
expect "a newer cask bundling a newer Pi passes" [ $? -eq 0 ]

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

BUNDLE=com.example.other run 1.2.17 1.2.17 1.2.17 --check
expect "wrong bundle id exits 1" [ $? -eq 1 ]
expect "wrong bundle id is named" grep -q '^FAIL  bundle id is not com.kunchenguid.pi-launcher' "$sandbox/out"

VERIFY_EXIT=1 run 1.2.17 1.2.17 1.2.17 --check
expect "invalid code signature exits 1" [ $? -eq 1 ]
expect "invalid code signature is named" grep -q '^FAIL  code signature invalid' "$sandbox/out"

SPCTL_EXIT=3 run 1.2.17 1.2.17 1.2.17 --check
expect "Gatekeeper rejection exits 1" [ $? -eq 1 ]
expect "Gatekeeper rejection is named" grep -q '^FAIL  Gatekeeper rejects' "$sandbox/out"

rm "$stubs/pi-signed"
run 1.2.17 1.2.17 1.2.17 --check
expect "pi-signed missing from PATH exits 1" [ $? -eq 1 ]
expect "missing pi-signed is named" grep -q '^FAIL  pi-signed (not on PATH) does not link into Pi Launcher.app' "$sandbox/out"

ln -s "$sandbox/elsewhere/pi-launcher" "$stubs/pi-signed"
run 1.2.17 1.2.17 1.2.17 --check
expect "pi-signed linking outside Pi Launcher.app exits 1" [ $? -eq 1 ]
expect "misplaced pi-signed is named" grep -q "^FAIL  pi-signed ($stubs/pi-signed) does not link into Pi Launcher.app" "$sandbox/out"
ln -sf "$app/Contents/MacOS/pi-launcher" "$stubs/pi-signed"

commit_pin 1.2.17 1.4.0 "fix: bundle Pi 1.4.0"
run 1.2.17 1.2.17 1.2.17 --check
expect "a HEAD pin past the release tag passes (cask bundles the tag's Pi)" [ $? -eq 0 ]
expect "the tag's pin is the one compared" grep -q '^ok    pi-signed runs bundled Pi 1.3.0 (pinned at v1.2.17)' "$sandbox/out"

BUNDLED_PI=1.4.0 run 1.2.17 1.2.17 1.2.17 --check
expect "a bundled Pi matching only the HEAD pin exits 1" [ $? -eq 1 ]

BUNDLED_PI=1.9.9 run 1.2.18 1.2.18 1.2.18 --check
expect "a release whose tag is not fetched passes" [ $? -eq 0 ]
expect "the missing tag warns" grep -q '^warn  .*no packaging/pi-release.json pin at tag v1.2.18' "$sandbox/out"

PI_EXIT=1 run 1.2.18 1.2.18 1.2.18 --check
expect "a failing pi-signed --version still fails without a tag" [ $? -eq 1 ]

run 1.2.17 1.2.17 1.2.17 --bogus
expect "unknown argument exits 2" [ $? -eq 2 ]

if [ "$fails" -eq 0 ]; then
  echo "install_pi_launcher_test: ALL PASS"
else
  echo "install_pi_launcher_test: $fails FAILURE(S)"
  exit 1
fi
