# Fleet

Control directory for the repo fleet under `~/github`.
Everything here is generated or maintained by the fleet tooling; the single source of truth is `manifest.yaml`.

## What each repo actually is

One line each, learned from the repos themselves, not their names.

| Repo | What it is |
|---|---|
| lavish-axi | CLI editor/renderer for HTML artifacts ("HTML is the new markdown"); ships a Claude skill and plugin. |
| firstmate | Agent-crew orchestration distro; the clone itself is the product (AGENTS.md + 130 `fm-*` scripts + skills), nothing installs. |
| no-mistakes | Go CLI ship gate: review, tests, lint, docs, push, PR, CI as one pipeline; has its own launchd daemon. |
| axi | The AXI (Agent eXperience Interface) design principles, catalog, and a JS SDK monorepo; library, no binary. |
| chrome-devtools-axi | Agent-ergonomic browser automation CLI (navigate, snapshot, click, inspect). |
| gh-axi | GitHub operations CLI for agents; a standalone npm CLI, NOT a gh extension. |
| autopreso | Realtime speech-to-presentation CLI (node >= 24). |
| baby-menu | Electron macOS menu-bar app that "becomes anything you ask it to be". |
| tasks-axi | Backlog/task CLI with pluggable backends (markdown, sqlite, remote). |
| quota-axi | LLM subscription quota window reporting CLI. |
| treehouse | Go CLI: git worktree manager ("manage worktrees without managing worktrees"). |
| short-pipe | Electron app for cutting video shorts. |
| trial-by-combat | Benchmark arena: two LLMs fight on a 9x9 grid. |
| justroll | Small node CLI (dice/rolling utility). |
| presize | presize.io web app monorepo: bulk image resize/crop (dormant; pins pnpm 8). |
| org-bench | TypeScript benchmark monorepo (org-level agent benchmarking). |
| superpowers-bench | Benchmark: can an agent pick the right skills for the right tasks (default branch: master). |
| programbench-bench | Harness-variation study on the ProgramBench paper's tasks; shell + python + Docker. |
| dotfiles-nix | nix-darwin + home-manager flake; owns shell/git config, PATH, and the sync agent. THE config source of truth. |
| gnhf | Overnight agent-run manager ("good night, have fun"). |
| wheelhouse | IssueOps command center running on GitHub Actions; fork state tracked in its manifest notes. |

## Aliases

Generated into `aliases.zsh` by `gen-aliases.sh` from the manifest; sourced by
`dotfiles-nix/files/zsh/ic-workflow.zsh` (interactive shells only). Never hand-edit
`aliases.zsh`; edit the manifest's `aliases:` fields and re-run `gen-aliases.sh`.

Jump aliases: `cdlav cdfm cdnm cdaxi cdcda cdgha cdap cdbm cdta cdqa cdth cdsp cdtbc cdjr cdpz cdob cdsb cdpb cddot cdgnhf cdwh`.
Run aliases (only defined when the binary exists): `lav gha ap jr` new, plus the pre-existing `nm cda ta qa th gn` from ic-workflow.zsh (`nm` deliberately shadows `/usr/bin/nm`).
Fleet commands: `fleet-sync`, `fleet-sync-dry`, `fleet-doctor`, `fleet-status`, `fleet-cd`.

## How sync works

Two layers, no duplicates, forks stay pristine mirrors:

1. Local: `dotfiles-nix/files/bin/sync-forks` (manifest-driven) runs daily at 10:00 via the home-manager launchd agent `org.nix-community.home.sync-forks`, with `RunAtLoad` so a run missed while asleep fires on wake. Per repo it: re-asserts identity (strips local `user.email`/`user.name` overrides; a wrong resolved identity fails the repo); skips dirty trees, in-progress rebases/merges, and non-default branches; fetches and verifies `upstream/<branch>` exists; fast-forwards only (`--ff-only`); reports DIVERGED forks and never merges, rebases, or server-syncs them; calls `gh repo sync -b <branch>` server-side only when the fork has no local-only commits; pushes the default branch (normal push); re-runs the manifest `install` command when the repo updated, and a failed reinstall counts as a failure. Failures notify via macOS notification; success is silent.
2. Server-side (works with the Mac off): the private `shreejitverma/fleet-ops` repo runs `.github/workflows/fleet-sync.yml` daily at 14:00 UTC, looping `repos.txt` (mirrored from this manifest's `sync: true` list) with `gh repo sync`. Per-fork workflow files were deliberately rejected: a workflow commit on a fork's default branch permanently diverges it, breaking ff-only sync. Needs the `FLEET_SYNC_TOKEN` secret (fine-grained PAT, Contents read-write).

`dotfiles-nix` itself is `sync: false`: it carries fork-specific commits and syncs from upstream via deliberate merge-commit PRs (see its CLAUDE.md); ff-only can never apply to it.

## Logs

- `~/github/.fleet/logs/sync-YYYYMMDD.log` - one per day, 30-day rotation.
- `~/github/.fleet/logs/launchd.{out,err}.log` - launchd-level output.
- `~/github/.fleet/logs/bootstrap-*.log` - bootstrap runs.

`./doctor.sh` also checks that `grok` on PATH is xAI Grok Build (not Homebrew's unrelated regex tool of the same name), that the only copy is `~/.local/bin/grok` (the official installer; a second npm copy is a FAIL), and that `~/.grok/AGENTS.md` is the separate personal-layer file from `~/github/agents/GROK.md`, not Claude's `~/AGENTS.md`.
Grok is vendor-installed, not a fleet fork; a missing binary is a warning, not a FAIL.

## Add a repo to the fleet

1. Fork it under `shreejitverma` and clone to `~/github/<name>`.
2. Add a manifest entry (copy an existing one; set `upstream`, `default_branch`, `install`, `provides_bin`, `aliases`).
3. Regenerate the server-side list: `awk '/^- name:/ {name=$3} /^  sync: true/ {print name}' manifest.yaml > repos.txt`.
4. Run `./gen-aliases.sh`, then `./bootstrap.sh`, then `./doctor.sh`, and ship the change (this directory is the fleet-ops repo).

This directory IS the private `shreejitverma/fleet-ops` repo: manifest, scripts, identity files, and the server-side workflow are all version-controlled together. `logs/` and backups stay untracked.
On a fresh machine, apply the dotfiles-nix rebuild (nix plus the base toolchain) manually before `bootstrap.sh` can fully succeed; bootstrap reports failures honestly and converges over re-runs.

## Disable sync

- One repo: set `sync: false` in its manifest entry.
- Everything: set `launchd.agents.sync-forks.enable = false` in `dotfiles-nix/nix/home/darwin.nix` and rebuild (`rebuild` alias), or one-off: `launchctl bootout gui/$(id -u)/org.nix-community.home.sync-forks`.

## Undo everything the fleet setup did

- Identity: restore `~/.gitconfig.bak.<ts>` over `~/.gitconfig` (re-adds the stale stevens.edu email; not recommended).
- dotfiles-nix changes (git config includeIf + github.user, daily sync schedule, manifest-driven sync-forks, aliases hook): `git log` in `~/github/dotfiles-nix`, revert the fleet commits, rebuild.
- Installed CLIs: `npm -g unlink autopreso justroll` (the others predate the fleet).
- This directory: `rm -rf ~/github/.fleet` (nothing else references it except the includeIf, which degrades gracefully - git ignores a missing include file).

## Decisions on record

- Workspace root is `~/github` (pre-existing reality), not `~/dev`.
- No mise/asdf introduced: Homebrew node v26 satisfies every engine pin in the fleet; presize's pnpm@8 is honored by corepack via its `packageManager` field. Revisit only if a repo pins an incompatible runtime.
- Sync is ff-only (2026-08-11 decision); a diverged fork stays diverged until manually reconciled (wheelhouse was, on 2026-08-12 - see its manifest notes).
- `pull.rebase = true` kept from the nix config (prompt suggested false; overridden by explicit decision).
