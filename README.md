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
| compact-adviser | Agent plugin that hints when a session is at a safe point to `/compact` (TypeSafe Jev judge); wired into Claude Code and Grok, no PATH bin. |
| acp-mock | Deterministic ACP agent over stdio, the token-free test double for ACP clients; `acp-mock` is npm-linked, while gnhf and baby-menu consume the npm package. |
| pi-launcher | Signed, notarized macOS app that runs the bundled official Pi as `pi-signed` (firstmate's `pi-signed` harness); installed from `kunchenguid/tap`, never built from the clone. |
| archify | Agent skill (parent `tt-a1i/archify`) that turns a description, Mermaid, or a traced repository into validated interactive HTML diagrams and one-page explainers; runs from the clone, linked into every agent by `ic-link`, no PATH bin. |
| runner-up | Go CLI that runs GitHub Actions jobs on your own machines, one fresh container, VM, or account per job, through runner scale sets; built into `~/go/bin` by `bin/install-runner-up.sh`, and this Mac's coordinator runs cryozen's Apple-silicon macOS CI in fresh tart clones (see "runner-up coordinator" below). |

## Aliases

Generated into `aliases.zsh` by `gen-aliases.sh` from the manifest; sourced by
`dotfiles-nix/files/zsh/ic-workflow.zsh` (interactive shells only). Never hand-edit
`aliases.zsh`; edit the manifest's `aliases:` fields and re-run `gen-aliases.sh`.

Jump aliases: `cdlav cdfm cdnm cdaxi cdcda cdgha cdap cdbm cdta cdqa cdth cdsp cdtbc cdjr cdpz cdob cdsb cdpb cddot cdgnhf cdwh cdca cdacp cdpil cdarch cdru`.
Run aliases (only defined when the binary exists): `lav gha ap jr` new, plus the pre-existing `nm cda ta qa th gn` from ic-workflow.zsh (`nm` deliberately shadows `/usr/bin/nm`).
Fleet commands: `fleet-sync`, `fleet-sync-dry`, `fleet-doctor`, `fleet-status`, `fleet-cd`.
`fleet-doctor` (`./doctor.sh`) also checks that `grok` on PATH is xAI Grok Build (not Homebrew's unrelated regex tool of the same name), that the only copy is `~/.local/bin/grok` (the official installer; a second npm copy is a FAIL), and that `~/.grok/AGENTS.md` is the separate personal-layer file from `~/github/agents/GROK.md`, not Claude's `~/AGENTS.md`.
Grok is vendor-installed, not a fleet fork; a missing binary is a warning, not a FAIL.

## How sync works

Two layers, no duplicates, forks stay pristine mirrors:

1. Local: `dotfiles-nix/files/bin/sync-forks` (manifest-driven) runs daily at 10:00 via the home-manager launchd agent `org.nix-community.home.sync-forks`, with `RunAtLoad` so a run missed while asleep fires on wake. Per repo it: re-asserts identity (strips local `user.email`/`user.name` overrides; a wrong resolved identity fails the repo); skips dirty trees, in-progress rebases/merges, and non-default branches; fetches and verifies `upstream/<branch>` exists; fast-forwards only (`--ff-only`); reports DIVERGED forks and never merges, rebases, or server-syncs them; calls `gh repo sync -b <branch>` server-side only when the fork has no local-only commits; pushes the default branch (normal push); re-runs the manifest `install` command when the repo updated, and a failed reinstall counts as a failure. Failures notify via macOS notification; success is silent.
2. Server-side (works with the Mac off): the public `shreejitverma/fleet-ops` repo runs `.github/workflows/fleet-sync.yml` daily at 14:00 UTC, looping `repos.txt` (mirrored from this manifest's `sync: true` list) with `gh repo sync` via `bin/fleet-sync-remote.sh`. One repo's failure is printed and the loop continues. Per-fork workflow files were deliberately rejected: a workflow commit on a fork's default branch permanently diverges it, breaking ff-only sync. Needs the `FLEET_SYNC_TOKEN` secret (fine-grained PAT, Contents read-write and Workflows read-write, on every sync:true repo including ones added later). A fork missing from the token's repository list fails with HTTP 403 and turns every run red while the local layer still syncs it, so `doctor.sh` reads the last completed run through `bin/fleet-sync-last-run.sh` and FAILs when it failed, timed out, or did not start, naming each repo it could not sync. Pull requests and pushes to main run `.github/workflows/ci.yml`, which shellchecks every fleet shell script and executes the hermetic scripts under `tests/`. That workflow is what makes a pull request report a check; `fleet-sync.yml` does not run on pull requests.

`dotfiles-nix` itself is `sync: false`: it carries fork-specific commits and syncs from upstream via deliberate merge-commit PRs (see its CLAUDE.md); ff-only can never apply to it.
`firstmate` is `sync: false` for the same reason since 2026-09-19: its fork carries fork-specific commits that are not contributed to the parent, so parent updates arrive through a deliberate sync-upstream merge PR on the fork.
Neither sync layer touches `sync: false` forks.
`doctor.sh` warns when the last local sync log's done line lists them in a non-empty `manual:[...]` field (behind upstream); the per-fork counts are on that log's `manual-sync` lines.

## Signed Pi Launcher

`pi-launcher` is the one fleet repo whose installed artifact is not built from its clone.
Its value is the notarized Developer ID identity (Team `9T2J7MNUP9`), and `make app` in the clone builds an unsigned dev app.
The clone is the audited source and the version pin; the manifest `install` is `bin/install-pi-launcher.sh`, which installs or upgrades the `kunchenguid/tap/pi-launcher` cask.
When the cask is still behind the fork's release (the tap lags, or a download failed), it refreshes the taps once and retries.
A nonzero `brew` exit only warns; the checks on the installed result alone decide the exit status.
It then verifies the cask version against the fork's `.release-please-manifest.json`, that `pi-signed` links into `/Applications/Pi Launcher.app`, the code signature, the Team ID, the bundle id, Gatekeeper, and, when the cask is exactly the fork's release, that the bundled Pi matches `packaging/pi-release.json` at the fork's release tag `v<version>` (HEAD may already pin the next Pi); a missing tag only warns.
`doctor.sh` runs the same checks read-only with `--check`, and `tests/install_pi_launcher_test.sh` covers the decision logic with stubbed `brew`, `codesign`, and `spctl` in CI.
If a sync lands a release commit before the tap publishes it, the reinstall fails and notifies once; rerun `bin/install-pi-launcher.sh` later, or let `up`'s `brew upgrade` catch up.

GitHub Actions is disabled on the `acp-mock`, `pi-launcher`, and `runner-up` forks.
Their upstream workflows commit to `main` on their own: release-please on push, and pi-launcher's daily Pi-pin cron auto-merges its release PR.
On a mirror, either would diverge the fork and break ff-only sync.
Re-enable with `gh api -X PUT repos/shreejitverma/<repo>/actions/permissions -F enabled=true`.

## runner-up coordinator

`runner-up` serves `cryozenai/cryozen`'s two Apple-silicon `macos-latest` CI jobs from this Mac, each in a fresh tart clone of macOS 26 that is deleted when the job ends.
macOS minutes bill at ten times Linux minutes on that private repository, and those two jobs are about half of each CI run's billed minutes.

- Coordinator: the launchd agent `org.nix-community.home.runner-up` from `dotfiles-nix/nix/home/darwin.nix`, running `~/go/bin/runner-up serve` while `~/Library/Application Support/runner-up/config.json` exists; log at `~/Library/Logs/runner-up.log`.
- Setup: pool `cryozen-macos`, two tart places of 4 cores and 8192 MB cloning the local image `ci-tahoe`, 4 cores and 12288 MB always kept for the owner, and a one-hour job cap.
- Image: `bin/bake-runner-up-image.sh` builds `ci-tahoe` from `ghcr.io/cirruslabs/macos-tahoe-base:latest` with the guest DNS set to public resolvers, because with Cloudflare WARP on the host a guest's default resolver never answers and the runner fails with `Socket Error: HostNotFound`.
  It checks the candidate resolves GitHub's runner broker and reaches the GitHub API before swapping it in; rerun it after Cirrus Labs updates the base image, with at most one job running (macOS allows two VMs at once).
- Routing: cryozen's `ci.yml` sends those jobs to the pool named by the repository variable `CRYOZEN_MACOS_RUNNER` and to hosted `macos-latest` when it is unset.
- While this Mac is asleep or offline those jobs wait at GitHub, so before a trip run `gh variable delete CRYOZEN_MACOS_RUNNER -R cryozenai/cryozen`, and `gh variable set CRYOZEN_MACOS_RUNNER -R cryozenai/cryozen -b cryozen-macos` on return.
- Updates: `sync-forks` reruns `bin/install-runner-up.sh` after a fast-forward, which rebuilds and restarts a running coordinator; running jobs carry on through the restart.
  The setup names no `release`, so the coordinator never replaces the fleet build with a downloaded one.
- Health: `doctor.sh` runs `bin/install-runner-up.sh --check` (installed build matches the clone, `check-config` passes, coordinator running); `runner-up status` shows places and waiting jobs, and `runner-up usage` shows each job's sampled peak use for pool sizing.
- Stop entirely: delete the repository variable first, then move the setup file away; launchd stops the coordinator once the file is gone.
- tart comes from the official tap `openai/tools` (`cirruslabs/tart` moved to `openai/tart`); the old `cirruslabs/cli` tap is stale and fails under current Homebrew.

## Logs

- `~/github/.fleet/logs/sync-YYYYMMDD.log` - one per day, 30-day rotation.
- `~/github/.fleet/logs/launchd.{out,err}.log` - launchd-level output.
- `~/github/.fleet/logs/bootstrap-*.log` - bootstrap runs.

## Add a repo to the fleet

1. Fork it under `shreejitverma` and clone to `~/github/<name>`.
2. Add a manifest entry (copy an existing one; set `upstream`, `default_branch`, `install`, `provides_bin`, `aliases`).
3. Regenerate the server-side list: `awk '/^- name:/ {name=$3} /^  sync: true/ {print name}' manifest.yaml > repos.txt`.
4. Run `./gen-aliases.sh`, then `./bootstrap.sh`, then `./doctor.sh`, and ship the change (this directory is the fleet-ops repo).
5. If the entry is `sync: true`, add the fork to the `FLEET_SYNC_TOKEN` token's repository list (GitHub, Settings, Developer settings, Fine-grained tokens; a manual edit, there is no API), then run `gh workflow run fleet-sync.yml -R shreejitverma/fleet-ops` and confirm the run prints `ok` for it. Skipping this fails every server-side run with HTTP 403 from the day the change merges.

This directory IS the `shreejitverma/fleet-ops` repo: manifest, scripts, identity files, and the server-side workflow are all version-controlled together. `logs/` and backups stay untracked.
The repository is public, and that is safe by construction, so keep it that way only while these hold:

- Nothing secret is tracked: the identity email and the signing public key are already public on GitHub, and `gitleaks git .` found no leaks across the full history on 2026-11-06.
- `FLEET_SYNC_TOKEN` is read only by `fleet-sync.yml`, which runs on `schedule` and `workflow_dispatch` (repository writers only), never on `pull_request` or `pull_request_target`.
- `ci.yml` runs with `contents: read`, the default workflow token is read-only, and pull requests from forks never receive secrets.
- Workflow runs from every outside contributor's pull request wait for approval (`fork-pr-contributor-approval` set to `all_external_contributors` on 2026-11-06).

Being public is also what keeps the daily sync and CI off the free plan's Actions minutes.
Making it private would not withdraw the existing public fork, and it would start drawing on those minutes.

On a fresh machine, apply the dotfiles-nix rebuild (nix plus the base toolchain) manually before `bootstrap.sh` can fully succeed; bootstrap reports failures honestly and converges over re-runs.

## Disable sync

- One repo: set `sync: false` in its manifest entry, then regenerate `repos.txt` (step 3 of "Add a repo to the fleet") so the server-side loop drops it too and `doctor.sh` sees no drift. Record why in the entry's `notes:`.
- Everything: set `launchd.agents.sync-forks.enable = false` in `dotfiles-nix/nix/home/darwin.nix` and rebuild (`rebuild` alias), or one-off: `launchctl bootout gui/$(id -u)/org.nix-community.home.sync-forks`.

## Undo everything the fleet setup did

- Identity: restore `~/.gitconfig.bak.<ts>` over `~/.gitconfig` (re-adds the stale stevens.edu email; not recommended).
- dotfiles-nix changes (git config includeIf + github.user, daily sync schedule, manifest-driven sync-forks, aliases hook): `git log` in `~/github/dotfiles-nix`, revert the fleet commits, rebuild.
- Installed CLIs: `npm -g unlink autopreso justroll` (the others predate the fleet).
- This directory: `rm -rf ~/github/.fleet` (nothing else references it except the includeIf, which degrades gracefully - git ignores a missing include file).

## Decisions on record

- Workspace root is `~/github` (pre-existing reality), not `~/dev`.
- No mise/asdf introduced: Homebrew node v26 satisfies every engine pin in the fleet; presize's pnpm@8 is honored by corepack via its `packageManager` field. Revisit only if a repo pins an incompatible runtime.
- Sync is ff-only (2026-08-11 decision); a diverged fork stays diverged until manually reconciled (wheelhouse is reconciled by a sync-upstream merge PR - see its manifest notes).
- `pull.rebase = true` kept from the nix config (prompt suggested false; overridden by explicit decision).
