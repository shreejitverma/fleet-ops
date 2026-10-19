#!/usr/bin/env bash
# bootstrap.sh: bring this machine to the fleet's desired state from scratch.
# Idempotent: re-running changes nothing that is already correct.
#
# For every repo in manifest.yaml it:
#   1. clones the fork if missing (origin = shreejitverma/<name>),
#   2. ensures the upstream remote points at the manifest's upstream,
#   3. runs the repo's install command only when a declared binary is missing,
#   4. creates the npm global link for node CLIs whose bin is missing.
#
# It never touches dirty repos, never switches branches, never deletes.
set -euo pipefail

GH_ROOT="$HOME/github"
FLEET_DIR="$GH_ROOT/.fleet"
MANIFEST="$FLEET_DIR/manifest.yaml"
LOG_DIR="$FLEET_DIR/logs"
LOG="$LOG_DIR/bootstrap-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "$LOG_DIR"
log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" | tee -a "$LOG"; }

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
command -v git >/dev/null || { echo "git missing" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh missing (brew install gh; gh auth login)" >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated: run gh auth login" >&2; exit 1; }

# Emit "name|upstream|install|bins" per manifest entry.
entries() {
  awk '
    function flush() {
      if (name != "") printf "%s|%s|%s|%s\n", name, upstream, install, bins
      name = ""; upstream = ""; install = "none"; bins = ""
    }
    /^- name:/      { flush(); name = $3 }
    /^  upstream:/  { upstream = $2 }
    /^  install:/   { install = $0; sub(/^  install: */, "", install); gsub(/^"|"$/, "", install); gsub(/\\"/, "\"", install) }
    /^  provides_bin:/ {
      bins = $0; sub(/^  provides_bin: *\[/, "", bins); sub(/\].*/, "", bins); gsub(/,/, " ", bins)
    }
    END { flush() }
  ' "$MANIFEST"
}

log "===== bootstrap start ====="
failures=""

while IFS='|' read -r name upstream install bins; do
  d="$GH_ROOT/$name"

  # 1. Clone if missing.
  if [ ! -d "$d/.git" ]; then
    log "[$name] cloning shreejitverma/$name"
    gh repo clone "shreejitverma/$name" "$d" </dev/null >>"$LOG" 2>&1 \
      || { log "[$name] clone FAILED"; failures="$failures $name"; continue; }
  fi

  # 2. Upstream remote: create or correct, never touch origin.
  if [ -n "$upstream" ]; then
    want="https://github.com/$upstream.git"
    have=$(git -C "$d" remote get-url upstream 2>/dev/null || echo "")
    if [ -z "$have" ]; then
      git -C "$d" remote add upstream "$want"
      log "[$name] added upstream $want"
    elif [ "$have" != "$want" ]; then
      log "[$name] NOTE: upstream is $have, manifest says $want (left as-is; fix manifest or remote)"
    fi
  fi

  # 3. Install only when a declared binary is missing (idempotency).
  missing=""
  for b in $bins; do
    command -v "$b" >/dev/null 2>&1 || missing="$missing $b"
  done
  if [ -n "$missing" ] && [ "$install" != "none" ]; then
    log "[$name] installing (missing:$missing): $install"
    ( cd "$d" && eval "$install" ) </dev/null >>"$LOG" 2>&1 \
      || { log "[$name] install FAILED"; failures="$failures $name"; continue; }
    # 4. Node CLIs: the build does not put the bin on PATH by itself; the
    #    global npm link does. Create it if still missing.
    for b in $bins; do
      if ! command -v "$b" >/dev/null 2>&1 && [ -f "$d/package.json" ]; then
        log "[$name] npm link for $b"
        ( cd "$d" && npm link ) </dev/null >>"$LOG" 2>&1 || log "[$name] npm link FAILED"
      fi
    done
  fi

  # Final per-repo verdict.
  still=""
  for b in $bins; do
    command -v "$b" >/dev/null 2>&1 || still="$still $b"
  done
  if [ -n "$still" ]; then
    log "[$name] BIN STILL MISSING:$still"
    failures="$failures $name"
  else
    log "[$name] ok"
  fi
done < <(entries)

# Regenerate aliases from the manifest so the two never drift.
if [ -x "$FLEET_DIR/gen-aliases.sh" ]; then
  if "$FLEET_DIR/gen-aliases.sh" >>"$LOG" 2>&1; then
    log "aliases.zsh regenerated"
  else
    log "gen-aliases FAILED"
    failures="$failures gen-aliases"
  fi
fi

log "===== bootstrap done. failures:[${failures:- none} ] ====="
[ -z "$failures" ]
