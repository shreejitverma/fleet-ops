#!/usr/bin/env bash
# doctor.sh: read-only health check for the fleet. Exits non-zero on any FAIL.
# Complements dotfiles-nix's ic-doctor (toolchain-wide); this one is
# manifest-driven and covers exactly the fleet contract:
#   repos present + on default branch + correct remotes
#   identity resolves to Shreejit Verma <shreejitverma@gmail.com> everywhere
#   no local user.email/user.name overrides
#   every provides_bin resolves on PATH, duplicate copies on PATH are flagged
#     (and npm links point at the clones)
#   no alias/binary collisions from aliases.zsh
#   repos.txt matches the manifest's sync: true list (server-side drift)
#   sync LaunchAgent loaded, last sync run had no failures
#   smoke: every CLI answers --version or --help with exit 0
#   grok: xAI Grok Build on PATH (not Homebrew's regex grok) and separate AGENTS.md
set -uo pipefail

GH_ROOT="$HOME/github"
FLEET_DIR="$GH_ROOT/.fleet"
MANIFEST="$FLEET_DIR/manifest.yaml"
IDENT="Shreejit Verma <shreejitverma@gmail.com>"
AGENT_LABEL="org.nix-community.home.sync-forks"

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
warn() { printf '  warn  %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

[ -f "$MANIFEST" ] || { echo "FAIL: manifest missing at $MANIFEST"; exit 1; }

entries() {
  awk '
    function flush() {
      if (name != "") printf "%s|%s|%s|%s|%s\n", name, branch, upstream, kind, bins
      name = ""; branch = "main"; upstream = ""; kind = ""; bins = ""
    }
    /^- name:/           { flush(); name = $3 }
    /^  default_branch:/ { branch = $2 }
    /^  upstream:/       { upstream = $2 }
    /^  kind:/           { kind = $2 }
    /^  provides_bin:/   {
      bins = $0; sub(/^  provides_bin: *\[/, "", bins); sub(/\].*/, "", bins); gsub(/,/, " ", bins)
    }
    END { flush() }
  ' "$MANIFEST"
}

echo "== repos, remotes, identity =="
while IFS='|' read -r name branch upstream kind bins; do
  d="$GH_ROOT/$name"
  if [ ! -d "$d/.git" ]; then bad "$name: not cloned at $d"; continue; fi

  head=$(git -C "$d" symbolic-ref --short HEAD 2>/dev/null || echo DETACHED)
  [ "$head" = "$branch" ] && ok "$name: on $branch" || warn "$name: on $head (default $branch)"

  o=$(git -C "$d" remote get-url origin 2>/dev/null || echo "")
  case "$o" in
    *github.com[:/]shreejitverma/"$name"*) ok "$name: origin is the fork" ;;
    *) bad "$name: origin is '$o'" ;;
  esac
  u=$(git -C "$d" remote get-url upstream 2>/dev/null || echo "")
  case "$u" in
    *github.com[:/]"${upstream%%/*}"/"${upstream##*/}"*) ok "$name: upstream is $upstream" ;;
    *) bad "$name: upstream is '$u', manifest says $upstream" ;;
  esac

  a=$(git -C "$d" var GIT_AUTHOR_IDENT 2>/dev/null | sed 's/ [0-9][0-9]* [+-][0-9]*$//')
  c=$(git -C "$d" var GIT_COMMITTER_IDENT 2>/dev/null | sed 's/ [0-9][0-9]* [+-][0-9]*$//')
  { [ "$a" = "$IDENT" ] && [ "$c" = "$IDENT" ]; } \
    && ok "$name: identity resolves correctly" \
    || bad "$name: identity author='$a' committer='$c'"
  git -C "$d" config --local user.email >/dev/null 2>&1 \
    && bad "$name: local user.email override present" || true
  git -C "$d" config --local user.name >/dev/null 2>&1 \
    && bad "$name: local user.name override present" || true
done < <(entries)

echo "== binaries on PATH =="
while IFS='|' read -r name branch upstream kind bins; do
  for b in $bins; do
    p=$(command -v "$b" 2>/dev/null || echo "")
    if [ -z "$p" ]; then bad "$b: not on PATH"; continue; fi
    ok "$b -> $p"
    # More than one copy on PATH is how stale versions silently shadow fresh
    # installs (found live: ~/.local/bin/no-mistakes v1.45 over go/bin v1.49).
    dups=$(type -a "$b" 2>/dev/null | grep -c "is /")
    if [ "$dups" -gt 1 ]; then
      warn "$b: $dups copies on PATH: $(type -a "$b" | grep 'is /' | awk '{print $NF}' | tr '\n' ' ')"
    fi
    # npm-linked CLIs must link back to the clone, not a stale copy.
    nm_dir="/opt/homebrew/lib/node_modules/$name"
    if [ -f "$GH_ROOT/$name/package.json" ] && [ -e "$nm_dir" ]; then
      tgt=$(readlink "$nm_dir" 2>/dev/null || echo "not-a-link")
      case "$tgt" in
        *"/github/$name") ok "$b: npm link points at the clone" ;;
        *) bad "$b: $nm_dir -> $tgt (expected the clone)" ;;
      esac
    fi
  done
done < <(entries)

echo "== alias collisions =="
if [ -f "$FLEET_DIR/aliases.zsh" ]; then
  while IFS= read -r a; do
    # An alias name that is also a real executable is a shadowing collision.
    # nm is a known, deliberate exception (user config shadows /usr/bin/nm).
    if [ -n "$a" ] && command -v "$a" >/dev/null 2>&1; then
      if [ "$a" = "nm" ]; then warn "alias nm shadows /usr/bin/nm (deliberate)"; else
        bad "alias '$a' shadows $(command -v "$a")"
      fi
    fi
  done < <(grep -oE "^alias [A-Za-z0-9_-]+=|&& alias [A-Za-z0-9_-]+=" "$FLEET_DIR/aliases.zsh" \
           | grep -oE "[A-Za-z0-9_-]+=$" | tr -d '=')
  ok "alias collision scan complete"
else
  warn "aliases.zsh not generated yet"
fi

echo "== server-side list drift =="
if [ -f "$FLEET_DIR/repos.txt" ]; then
  want=$(awk '/^- name:/ {name=$3} /^  sync: true/ {print name}' "$MANIFEST")
  have=$(grep -v '^#' "$FLEET_DIR/repos.txt" | grep -v '^$')
  if [ "$want" = "$have" ]; then
    ok "repos.txt matches the manifest's sync: true list"
  else
    bad "repos.txt drifted from the manifest - regenerate it (see README)"
  fi
else
  warn "repos.txt missing (server-side sync list)"
fi

echo "== sync agent =="
if launchctl print "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1; then
  ok "LaunchAgent $AGENT_LABEL loaded"
else
  bad "LaunchAgent $AGENT_LABEL not loaded"
fi
last_log=$(ls -t "$FLEET_DIR"/logs/sync-*.log 2>/dev/null | head -1)
if [ -n "$last_log" ]; then
  done_line=$(grep "===== done" "$last_log" | tail -1)
  if [ -z "$done_line" ]; then
    warn "last sync log has no completion line ($last_log)"
  elif echo "$done_line" | grep -q "failed:\[ \]"; then
    ok "last sync run clean: $(basename "$last_log")"
    echo "$done_line" | grep -q "diverged:\[ \]" || warn "diverged forks present: see $last_log"
  else
    bad "last sync run had failures: $done_line"
  fi
else
  warn "no fleet sync log yet (agent runs daily at 10:00 or on load)"
fi

echo "== grok (xAI Grok Build) =="
# Grok is a vendor-installed CLI, not a fleet fork. Confirm the binary on PATH
# is xAI Grok Build rather than Homebrew's unrelated regex tool of the same name,
# and that duplicate copies are visible instead of silently shadowing.
if p=$(command -v grok 2>/dev/null); then
  if v=$(grok --version </dev/null 2>/dev/null | head -1); then
    case "$v" in
      grok\ *\[stable\]|grok\ *\[beta\]|grok\ *\[nightly\]) ok "grok $v ($p)" ;;
      *) bad "grok at $p is not xAI Grok Build (got: $v). Install with: curl -fsSL https://x.ai/cli/install.sh | bash" ;;
    esac
  else
    bad "grok at $p does not answer --version"
  fi
  if [ "$p" != "$HOME/.local/bin/grok" ]; then
    bad "grok on PATH is $p, want ~/.local/bin/grok (official installer; npm uninstall -g @xai-official/grok)"
  fi
  dups=$(type -a grok 2>/dev/null | grep -c "is /" || true)
  if [ "$dups" -gt 1 ]; then
    bad "grok: $dups copies on PATH: $(type -a grok | awk '/is \// {print $NF}' | tr '\n' ' ')(keep ~/.local/bin/grok; npm uninstall -g @xai-official/grok)"
  fi
  if [ -d "$HOME/.grok" ]; then
    case "$(readlink "$HOME/.grok/AGENTS.md" 2>/dev/null)" in
      "$GH_ROOT"/agents/GROK.md) ok "grok AGENTS.md is the separate personal-layer file" ;;
      "$HOME"/AGENTS.md|"$HOME"/.claude/CLAUDE.md) bad "grok AGENTS.md still points at Claude's file (run: ic-link)" ;;
      *) warn "grok AGENTS.md is not the versioned ~/github/agents/GROK.md (run: ic-link)" ;;
    esac
  else
    warn "grok binary present but ~/.grok missing"
  fi
else
  warn "grok not on PATH (install: curl -fsSL https://x.ai/cli/install.sh | bash)"
fi

echo "== smoke =="
if command -v timeout >/dev/null 2>&1; then
  run_limited() { timeout 10 "$@"; }
else
  warn "timeout not on PATH (brew install coreutils); smoke tests run without a 10s limit"
  run_limited() { "$@"; }
fi
while IFS='|' read -r name branch upstream kind bins; do
  # Only kind: cli binaries answer --version/--help. Running arbitrary
  # utility scripts (dotfiles' up, sync-forks, note, ...) with junk args
  # EXECUTES them - never smoke-test anything but real CLIs.
  [ "$kind" = "cli" ] || continue
  for b in $bins; do
    command -v "$b" >/dev/null 2>&1 || continue
    # </dev/null: never let a CLI wait on (or slurp) the loop's manifest pipe;
    # timeout: a hanging tool is a FAIL, not a stuck doctor.
    if run_limited "$b" --version </dev/null >/dev/null 2>&1 \
       || run_limited "$b" --help </dev/null >/dev/null 2>&1; then
      ok "$b answers --version/--help"
    else
      bad "$b: neither --version nor --help exits 0 within 10s"
    fi
  done
done < <(entries)

echo
if [ "$fail" -eq 0 ]; then echo "DOCTOR: all checks passed"; else echo "DOCTOR: FAILURES above"; fi
exit "$fail"
