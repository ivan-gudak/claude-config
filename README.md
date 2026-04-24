# claude-config

Shared Claude Code configuration: custom commands, workflow plugins, and hooks.

## What's here

| Path | Purpose |
|------|---------|
| `commands/impl.md` | `/impl` — structured implementation workflow with subagent optimisation |
| `commands/vuln.md` | `/vuln` — CVE fix workflow with parallel research subagents |
| `commands/upgrade.md` | `/upgrade` — dependency upgrade workflow with parallel compatibility research |
| `plugins/workflow-tools/` | `workflow-tools:test-baseline` — shared test-baseline agent (reuse in any command) |
| `hooks/notify-done.sh` | Desktop notification when Claude finishes a turn |
| `hooks/preload-context.sh` | Auto-injects git context when you submit /impl, /vuln, or /upgrade |
| `hooks/test-notify.sh` | Desktop notification with pass/fail count after every test suite run |

## Requirements

- Claude Code (latest)
- `python3` in PATH (used by `install.sh` for settings merge and by `preload-context.sh`)
- `git`

## Install

```bash
cd ~/.claude
git clone <repo-url> claude-config
cd claude-config && bash install.sh
```

## Update

```bash
cd ~/.claude/claude-config && git pull && bash install.sh
```

`install.sh` is idempotent — safe to re-run after every pull. New files added to the repo are automatically linked on the next run.

## How the commands work

### `/impl <description>` or `/impl @path/to/spec.md`

Structured implementation workflow:
1. Load description (supports `@file` syntax)
2. Clarify ambiguities (asks questions before writing a plan)
3. Write and present an implementation plan for approval
4. Implement, run tests, update docs/knowledge — using subagents for codebase exploration (before planning) and parallelising the post-implementation doc/knowledge/instructions updates
5. Output a structured report

### `/vuln <CVE-tokens>`

Fix security vulnerabilities. Accepts `JIRA-ID:CVE-ID` pairs or bare CVE IDs.

```
/vuln CVE-2023-46604
/vuln MGD-2423:CVE-2023-46604 CVE-2024-1234
```

NVD lookup, library detection in the repo, and test baseline all run in **parallel** before any fix is applied.

### `/upgrade <components>`

Upgrade libraries, runtimes, or GitHub Actions.

```
/upgrade springboot:latest java:21
/upgrade .github/workflows
```

Compatibility research and GitHub Actions scanning run in **parallel** before any changes are made.

## Hooks

Three hooks are active after install:

| Hook | Event | What it does |
|------|-------|-------------|
| `notify-done.sh` | Claude turn ends | Desktop notification (macOS: `osascript`; Linux: `notify-send`; WSL2: `wsl-notify-send` / PowerShell; fallback: bell) |
| `preload-context.sh` | Message submitted | If message starts with `/impl`, `/vuln`, or `/upgrade`: injects git branch, status, and recent commits before Claude starts |
| `test-notify.sh` | After every Bash call | If the command was a test runner (`mvn test`, `gradle test`, `npm test`, `pytest`, `make test`): sends notification with pass/fail count |

## Docker / AI containers

The repo lives at `~/.claude/claude-config/`. All symlinks created by `install.sh` stay within `~/.claude/`, so they resolve correctly inside any container that bind-mounts `~/.claude/` from the host (e.g. ai-containers).

Works on macOS, Linux, and WSL2 without platform-specific setup.

## Windows (native PowerShell)

`install.sh` and the hook scripts are bash-only and do not run on native Windows without WSL or Git Bash. The command files and plugin are plain text — no compatibility issue there.

### Manual installation

Copy these files into your Claude Code config directory (`%USERPROFILE%\.claude\`):

```
claude-config\commands\impl.md      → .claude\commands\impl.md
claude-config\commands\vuln.md      → .claude\commands\vuln.md
claude-config\commands\upgrade.md   → .claude\commands\upgrade.md
claude-config\plugins\workflow-tools\  → .claude\plugins\workflow-tools\
```

To update after a `git pull`, re-copy the changed files.

Alternatively, `mklink` (cmd) or `New-Item -ItemType SymbolicLink` (PowerShell, requires **Developer Mode** or Administrator) can create symlinks to avoid manual re-copying.

### Hooks — not supported on native Windows

The three hook scripts (`notify-done.sh`, `preload-context.sh`, `test-notify.sh`) require bash. On native Windows they will not run. Options:

- **WSL2** — the hooks work as-is; install from within a WSL2 shell using the normal `bash install.sh` path.
- **Git Bash** — if `bash` is in your PATH via Git Bash, the hooks may work but are untested.
- **No hooks** — the commands (`/impl`, `/vuln`, `/upgrade`) and the `workflow-tools` plugin are fully functional without the hooks. Hooks are enhancements only.
