# claude-config

Shared Claude Code configuration: custom commands, workflow plugins, and hooks.

## What's here

| Path | Purpose |
|------|---------|
| `commands/impl.md` | `/impl` — structured implementation workflow with subagent optimisation |
| `commands/vuln.md` | `/vuln` — CVE fix workflow with parallel research subagents |
| `commands/upgrade.md` | `/upgrade` — dependency upgrade workflow with parallel compatibility research |
| `plugins/workflow-tools/` | `workflow-tools:test-baseline` — shared test-baseline agent (reuse in any command) |
| `references/fix-vuln/` | Reference docs used by `/vuln` — build-system detection, NVD API usage |
| `references/upgrade/` | Reference docs used by `/upgrade` — ecosystem rules, LTS sources, compatibility constraints |
| `hooks/notify-done.sh` | Desktop notification when Claude finishes a turn |
| `hooks/preload-context.sh` | Auto-injects git context when you submit /impl, /vuln, or /upgrade |
| `hooks/test-notify.sh` | Desktop notification with pass/fail count after every test suite run |
| `install.sh` / `uninstall.sh` | Installer + uninstaller for macOS / Linux / WSL2 |
| `install.ps1` / `uninstall.ps1` | Installer + uninstaller for native Windows (PowerShell) — commands + plugin only, no hooks |

## Requirements

- Claude Code (latest)
- `python3` in PATH (used by `install.sh` for settings merge and by `preload-context.sh`)
- `git`

## Install

> **On native Windows?** Jump to the [Windows section](#windows-native-powershell) — `install.sh` is bash-only and won't run outside WSL2 / Git Bash.

First-time setup (macOS / Linux / WSL2):

```bash
cd ~/.claude
git clone <repo-url> claude-config
cd claude-config && bash install.sh
```

Already have the repo? Skip the clone and just update:

```bash
cd ~/.claude/claude-config && git pull && bash install.sh
```

`install.sh` is idempotent — safe to re-run after every pull. New files added to the repo are automatically linked on the next run.

**Install flags:**

| Flag | Effect |
|------|--------|
| `--no-hooks` | Install commands and plugin only; skip hook scripts and `settings.json` merge. Use this if you don't want notifications or auto-injected context. |
| `--no-plugin` | Skip the `workflow-tools` plugin symlink. Note: `/vuln` and `/upgrade` use `workflow-tools:test-baseline`, so this will degrade those commands. |
| `--help` | Show usage. |

## Uninstall

macOS / Linux / WSL2:

```bash
cd ~/.claude/claude-config && bash uninstall.sh
```

Native Windows:

```powershell
cd $env:USERPROFILE\.claude\claude-config
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes the symlinks (or copies) the installer created and strips the hook entries from `~/.claude/settings.json`. The repo itself is left intact — delete it separately (`rm -rf ~/.claude/claude-config` or `Remove-Item -Recurse -Force`).

## Commands

### `/impl`

```
/impl <description>
/impl @path/to/spec.md
```

Structured implementation workflow with mandatory clarification, planning, and knowledge persistence.

**Phases:**

1. **Load** — inline description or `@file` (reads the file, supports embedded images)
2. **Clarify** — analyzes the description for ambiguities; asks structured questions with multiple-choice answers before writing anything. Skips if nothing is ambiguous.
3. **Explore** — spawns an Explore subagent to map relevant files, patterns, test locations, and naming conventions. Result feeds the plan; no file reads pollute the main context.
4. **Plan** — produces a written plan (goal, approach, steps, files, tests, assumptions, out-of-scope) and asks for approval before touching any code.
5. **Implement** — works through each step, runs linters/builds/tests, fixes failures. After verifying the outcome, spawns three agents **in parallel**:
   - **Documentation agent** — scans for README/CHANGELOG/docs; applies minimal updates if the change is user-facing (skips for bug fixes and refactors)
   - **Knowledge agent** — checks `~/.claude/memory/` and `.claude/memory/`; appends a structured entry if the implementation produced reusable insights
   - **Instructions agent** — checks `CLAUDE.md` and `~/.claude/CLAUDE.md`; applies additive guardrails only if the implementation revealed a missing rule
6. **Report** — structured summary: what was built, files changed, commands run, knowledge/instructions/docs outcome.

**Examples:**

```
/impl add pagination to the user list endpoint
/impl @specs/2026-04-payment-refactor.md
```

---

### `/vuln`

```
/vuln <token> [<token> ...]
```

Fix one or more CVE vulnerabilities end-to-end: research → fix → verify → PR.

**Token formats:**

| Token | When to use |
|-------|-------------|
| `CVE-2023-46604` | bare CVE — no Jira ticket |
| `MGD-2423:CVE-2023-46604` | Jira ticket linked to a CVE |

Non-CVE identifiers (`CWE-*`, `OWASP 2021:A01`) are skipped with a warning.

**What happens:**

1. **Parse & filter** — extracts CVE IDs and optional Jira IDs; infers the `NOJIRA` placeholder convention from git history.
2. **Research (parallel)** — for every CVE and simultaneously:
   - **NVD agent** — fetches affected package, vulnerable version range, minimum safe version, and CVE description from the NVD API
   - **Detect agent** — scans the repo's build files (`pom.xml`, `build.gradle`, `package.json`, `requirements.txt`, `go.mod`, `Cargo.toml`) for the dependency and its current version
   - **Baseline agent** (`workflow-tools:test-baseline`) — runs the full test suite once and records all passing tests
3. **Merge** — combines NVD data, detected version, and safe target; skips CVEs where the library isn't found.
4. **Fix** — applies the minimal version bump (patch/minor preferred; major only if unavoidable), one CVE at a time.
5. **Verify** — builds the project, re-runs tests, diffs against baseline. If previously-green tests fail, asks whether to proceed, revert, or investigate.
6. **Commit & PR** — branch named after Jira ID + CVE ID (matching project convention); commit message includes CVE description, vulnerable range, and safe version; PR body summarises everything.

**Examples:**

```
/vuln CVE-2023-46604
/vuln MGD-2423:CVE-2023-46604 CVE-2024-1234
/vuln CVE-2024-1234 CVE-2024-5678 CVE-2024-9999
```

---

### `/upgrade`

```
/upgrade <token> [<token> ...]
```

Upgrade libraries, runtimes, build tools, or GitHub Actions with compatibility checking before any file is changed.

**Token formats:**

| Token | Meaning |
|-------|---------|
| `springboot:3.3.11` | exact target version |
| `springboot:minor` | latest patch on the current minor (e.g. `3.1.x → 3.1.12`) |
| `springboot:latest` | highest stable release |
| `node:lts` | latest LTS release (looks up official LTS source) |
| `springboot` | highest version compatible with everything else in the repo |
| `.github/workflows` | update all GitHub Actions `uses:` pins to latest release tags |

**Phase 1 — planning (no files changed):**

1. Inventories current versions from build files, runtime files, and CI YAML.
2. Resolves the target version for each token.
3. Spawns two agents **in parallel**:
   - **Compatibility agent** — fetches release notes and changelogs; returns breaking changes, required companion upgrades (e.g. Spring Boot major → Hibernate, Mockito), and runtime version requirements
   - **GitHub Actions agent** — scans `.github/workflows/` and applies `uses:` pin updates in-place (only spawned if the directory exists)
4. Reviews compatibility findings; surfaces conflicts with ranked resolution options (lower version / upgrade blocker / skip).
5. Presents the full upgrade plan and asks for confirmation before proceeding.

**Phase 2 — execution (one component at a time):**

1. Runs `workflow-tools:test-baseline` once and stores the result for all components.
2. For each component: detect → plan changes → apply → companion upgrades → build → test → compare against baseline.
3. Auto-fixes straightforward test breakage (renamed imports, updated assertion syntax); asks for guidance if not auto-fixable.
4. Prints a summary table on completion.

**Examples:**

```
/upgrade springboot:latest
/upgrade springboot:latest java:21 hibernate:latest
/upgrade node:lts
/upgrade .github/workflows
/upgrade springboot:3.3.11 java:21 gradle:latest .github/workflows
```

**Output:**

```
## Upgrade Summary

| Component  | Before | After  | Status  | Notes                       |
|------------|--------|--------|---------|-----------------------------|
| springboot | 3.1.4  | 3.3.11 | OK      | Also upgraded hibernate 6.4 |
| java       | 17     | 21     | OK      | Updated 2 test files        |
| redis      | -      | -      | SKIPPED | Not found in project        |

Tests: 142 passed, 0 regressions (baseline: 142 passing)
```

> All changes are left **uncommitted** on the current branch.

---

## Plugin agent: `workflow-tools:test-baseline`

A reusable agent used internally by `/vuln` and `/upgrade`. You can also invoke it directly from any command or custom agent.

**What it does:** runs the project's full test suite, parses the output, and returns a structured result suitable for before/after regression comparison.

**Framework detection** (in order):

| Detected file | Framework | Command |
|---------------|-----------|---------|
| `pom.xml` | Maven | `mvn test -q` |
| `build.gradle` / `build.gradle.kts` | Gradle | `./gradlew test` (or `gradle test`) |
| `package.json` | npm/Jest | value of `scripts.test`, or `npm test` |
| `pyproject.toml` / `setup.py` / `pytest.ini` | pytest | `pytest -v` |
| `Makefile` with a `test` target | Make | `make test` |

If no framework is detected, it returns a structured result with `Framework: not detected` and zero counts rather than failing.

**Output structure:**

```markdown
## Test Baseline
- **Framework**: Maven
- **Command**: `mvn test -q`
- **Total**: 142 | **Passing**: 140 | **Failing**: 2 | **Skipped**: 0

### Pre-existing failures
com.example.FooTest#testBar
com.example.FooTest#testBaz

### Passing tests
com.example.UserServiceTest#shouldCreateUser
com.example.UserServiceTest#shouldDeleteUser
...
```

Pre-existing failures are labelled so callers can distinguish them from regressions introduced by a change.

**How to use it in your own commands or agents:**

```
Use the Agent tool with subagent_type "workflow-tools:test-baseline".
Pass the project root as context. Store the returned baseline for later comparison.
```

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

`install.ps1` handles native Windows installation. It creates symlinks for the command files and the plugin, falling back to file copies if symlink creation isn't permitted.

**First-time setup:**

```powershell
cd $env:USERPROFILE\.claude
git clone <repo-url> claude-config
cd claude-config
powershell -ExecutionPolicy Bypass -File install.ps1
```

**Update after a `git pull`:**

```powershell
cd $env:USERPROFILE\.claude\claude-config
git pull
powershell -ExecutionPolicy Bypass -File install.ps1
```

Symlinks on Windows require either **Developer Mode** (Settings → For developers) or running PowerShell as **Administrator**. Without either, `install.ps1` automatically copies the files instead — still functional, but note: with copies, a `git pull` requires re-running `install.ps1` to re-copy the updated files. With symlinks, `git pull` is enough.

**Install flags:**

| Flag | Effect |
|------|--------|
| `-UseCopy` | Force file copy even if symlinks would work. Useful if you want portable paths. |
| `-NoPlugin` | Skip the `workflow-tools` plugin. |

**Uninstall:**

```powershell
cd $env:USERPROFILE\.claude\claude-config
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

Removes the command and plugin items (whether they were installed as symlinks or copies). If `python` or `python3` is on PATH, also strips the three hook entries from `settings.json` — useful if you previously installed via WSL2's `install.sh`.

### Hooks — not supported on native Windows

The three hook scripts (`notify-done.sh`, `preload-context.sh`, `test-notify.sh`) require bash. On native Windows they will not run, and `install.ps1` does not attempt to install them. Options:

- **WSL2** — if you run Claude Code from a WSL2 shell, you're on Linux: use the standard `bash install.sh` instructions above, hooks included.
- **Git Bash** — if `bash` is in your PATH via Git Bash, the hooks may work but are untested.
- **No hooks** — the commands (`/impl`, `/vuln`, `/upgrade`) and the `workflow-tools` plugin are fully functional without the hooks. Hooks are enhancements only.
