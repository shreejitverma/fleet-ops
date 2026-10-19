#!/usr/bin/env bash
# install-pi-launcher.sh: install or upgrade the signed Pi Launcher app from
# kunchenguid/tap, then prove it is upstream's notarized build at (or past)
# the version the synced pi-launcher fork pins.
#
# The clone is the audited source and the version pin, never the build
# source: `make app` there produces an unsigned dev app, and the product is
# the Developer ID identity (Team 9T2J7MNUP9) that firstmate's pi-signed
# harness and credential tools such as Automic Vault bind to.
#
# Usage:
#   install-pi-launcher.sh          install or upgrade, then verify (manifest install)
#   install-pi-launcher.sh --check  verify only, changes nothing (doctor.sh)
# Prints one "ok"/"FAIL" line per check and exits 1 on any FAIL.
set -uo pipefail

CASK="kunchenguid/tap/pi-launcher"
TEAM_ID="9T2J7MNUP9"
BUNDLE_ID="com.kunchenguid.pi-launcher"
CLONE="${PI_LAUNCHER_CLONE:-$HOME/github/pi-launcher}"

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
bad() {
  printf 'FAIL  %s\n' "$*"
  fail=1
}

# release-please (simple strategy) records the released version under ".".
want=$(sed -n 's/^ *"\.": *"\([^"]*\)".*/\1/p' "$CLONE/.release-please-manifest.json" 2>/dev/null)
pin=$(sed -n 's/^ *"version": *"\([^"]*\)".*/\1/p' "$CLONE/packaging/pi-release.json" 2>/dev/null)
if [ -z "$want" ] || [ -z "$pin" ]; then
  bad "cannot read the pinned versions from $CLONE (.release-please-manifest.json, packaging/pi-release.json)"
  exit 1
fi

cask_version() { brew list --cask --versions pi-launcher 2>/dev/null | awk '{print $2}'; }
# version_ge A B: A >= B in version order (1.2.10 sorts after 1.2.9).
version_ge() { [ -n "$1" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" = "$2" ]; }

if [ "$mode" = install ]; then
  if [ -z "$(cask_version)" ]; then
    brew install --cask "$CASK" || bad "brew install --cask $CASK failed"
  else
    brew upgrade --cask "$CASK" || bad "brew upgrade --cask $CASK failed"
  fi
  # The tap is bumped only after upstream's signed release workflow finishes,
  # so a sync can land the release commit before the cask exists. Refresh the
  # taps once and retry before reporting the version check below as failed.
  if [ "$fail" -eq 0 ] && ! version_ge "$(cask_version)" "$want"; then
    if ! { brew update --quiet && brew upgrade --cask "$CASK"; }; then
      bad "brew update and upgrade retry failed"
    fi
  fi
fi

have=$(cask_version)
if [ -z "$have" ]; then
  bad "cask pi-launcher is not installed (run: $0)"
  exit 1
fi
if version_ge "$have" "$want"; then
  ok "cask pi-launcher $have (fork pins $want)"
else
  bad "cask pi-launcher $have is older than the fork's $want; the tap may not have published it yet (rerun: $0)"
fi

bin=$(command -v pi-signed 2>/dev/null || true)
target=""
[ -n "$bin" ] && target=$(readlink "$bin" 2>/dev/null || true)
case "$target" in
  */"Pi Launcher.app/Contents/MacOS/pi-launcher")
    app=${target%/Contents/MacOS/pi-launcher}
    ok "pi-signed -> $target"
    ;;
  *)
    bad "pi-signed (${bin:-not on PATH}) does not link into Pi Launcher.app (got '${target:-nothing}')"
    exit 1
    ;;
esac

if codesign --verify --deep --strict "$app" 2>/dev/null; then
  ok "code signature valid"
else
  bad "code signature invalid: $app"
fi
sig=$(codesign -dv "$app" 2>&1)
if printf '%s\n' "$sig" | grep -qx "TeamIdentifier=$TEAM_ID"; then
  ok "signed by Team $TEAM_ID"
else
  bad "not signed by Team $TEAM_ID: $(printf '%s\n' "$sig" | grep '^TeamIdentifier=' || echo 'no TeamIdentifier')"
fi
if printf '%s\n' "$sig" | grep -qx "Identifier=$BUNDLE_ID"; then
  ok "bundle id $BUNDLE_ID"
else
  bad "bundle id is not $BUNDLE_ID: $(printf '%s\n' "$sig" | grep '^Identifier=' || echo 'none')"
fi
if spctl --assess --type execute "$app" 2>/dev/null; then
  ok "Gatekeeper accepts the app (notarized Developer ID)"
else
  bad "Gatekeeper rejects $app"
fi

# The bundled Pi matches the fork's pin only when the cask is exactly the
# fork's release; a newer cask (brew upgrade via `up`) bundles a newer Pi.
if pi_v=$("$bin" --version </dev/null 2>/dev/null); then
  if [ "$have" = "$want" ] && [ "$pi_v" != "$pin" ]; then
    bad "bundled Pi is $pi_v, the fork's packaging/pi-release.json pins $pin"
  else
    ok "pi-signed runs bundled Pi $pi_v"
  fi
else
  bad "pi-signed --version failed"
fi

exit "$fail"
