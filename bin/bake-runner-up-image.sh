#!/usr/bin/env bash
# bake-runner-up-image.sh: (re)build the local tart image runner-up's tart
# places clone for every job.
#
# Why a baked image instead of the Cirrus Labs base directly: tart guests
# resolve names through the host side of the shared network (192.168.64.1),
# and with Cloudflare WARP on the host that resolver never answers, so the
# GitHub runner in a fresh clone fails with "Socket Error: HostNotFound" and
# no job ever reaches it (found 2026-11-06). The baked image points the
# guest's DNS at public resolvers, which work with WARP on or off.
#
# The image is built under a temporary name, checked by resolving GitHub's
# runner broker and calling the GitHub API from inside the guest, and only
# then swapped in, so a failed bake never replaces a working image. Jobs
# already running keep their own clones; the next job clones the new image.
#
# It needs one free macOS VM slot (macOS runs at most two at once, and a
# busy runner-up place holds one), so run it while at most one job runs.
#
# Usage: bake-runner-up-image.sh
#   bakes ci-tahoe (the setup's places name it as "image") from
#   ghcr.io/cirruslabs/macos-tahoe-base:latest; takes no arguments.
set -euo pipefail

if [ "$#" -ne 0 ]; then
  echo "usage: $0 (takes no arguments)" >&2
  exit 2
fi

BASE="ghcr.io/cirruslabs/macos-tahoe-base:latest"
NAME="ci-tahoe"
NEXT="$NAME-next"
OLD="$NAME-old"
DNS_SERVERS=(1.1.1.1 1.0.0.1 8.8.8.8)

command -v tart >/dev/null || {
  echo "tart not found (brew install openai/tools/tart)" >&2
  exit 1
}

vm_exists() { tart list --format json | grep -q "\"Name\" *: *\"$1\""; }

cleanup() {
  tart stop "$NEXT" >/dev/null 2>&1 || true
  if vm_exists "$NEXT"; then tart delete "$NEXT" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

echo "pulling $BASE"
tart pull "$BASE"

if vm_exists "$NEXT"; then tart delete "$NEXT"; fi
tart clone "$BASE" "$NEXT"
tart run --no-graphics "$NEXT" >/dev/null 2>&1 &

ready=0
for _ in $(seq 1 100); do
  if tart exec "$NEXT" true >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 3
done
if [ "$ready" -ne 1 ]; then
  echo "the guest never answered tart exec (is a macOS VM slot free? see: tart list)" >&2
  exit 1
fi

tart exec "$NEXT" sudo -n networksetup -setdnsservers Ethernet "${DNS_SERVERS[@]}"
tart exec "$NEXT" sudo -n dscacheutil -flushcache
if ! tart exec "$NEXT" dscacheutil -q host -a name broker.actions.githubusercontent.com | grep -q '^name:'; then
  echo "the guest still cannot resolve broker.actions.githubusercontent.com" >&2
  exit 1
fi
code=$(tart exec "$NEXT" curl -sS -m 15 -o /dev/null -w '%{http_code}' https://api.github.com || true)
if [ "$code" != 200 ]; then
  echo "the guest cannot reach https://api.github.com (HTTP $code)" >&2
  exit 1
fi
echo "guest resolves GitHub and reaches its API"

tart exec "$NEXT" sudo -n sync
tart stop "$NEXT"
if vm_exists "$OLD"; then tart delete "$OLD"; fi
if vm_exists "$NAME"; then tart rename "$NAME" "$OLD"; fi
if ! tart rename "$NEXT" "$NAME"; then
  if vm_exists "$OLD"; then tart rename "$OLD" "$NAME"; fi
  echo "could not rename $NEXT to $NAME; kept the previous image" >&2
  exit 1
fi
trap - EXIT
echo "baked $NAME from $BASE"
if vm_exists "$OLD"; then
  tart delete "$OLD" || echo "could not delete the previous image $OLD; delete it by hand" >&2
fi
