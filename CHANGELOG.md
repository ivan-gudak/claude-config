# Changelog

All notable changes to this repo are recorded here.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versions follow semver at the **repo** level — individual plugin versions are tracked in their `plugin.json`.

## [Unreleased]

### Added
- **Model routing across `/impl`, `/vuln`, `/upgrade`.** Every command now classifies the task as `SIMPLE`, `MODERATE`, `SIGNIFICANT`, or `HIGH-RISK` before planning. `SIMPLE` / `MODERATE` continue on the currently selected model. `SIGNIFICANT` / `HIGH-RISK` route planning and post-implementation review through Opus and gate the test run on the review verdict.
- **`agents/risk-planner.md`** — new Opus-backed risk-weighted planner system prompt. Returns a structured plan with explicit security, migration, API-stability, concurrency, dependency, rollback, and test-adequacy sections. Refuses to run without a classification. Includes a re-classification escape hatch: if the task turns out to be `SIMPLE` / `MODERATE` on inspection, the planner says so and the caller falls back to the non-Opus path.
- **`agents/code-review.md`** — new Opus-backed post-implementation reviewer system prompt. Checks eight dimensions (correctness, security, architecture, edge cases, migration risks, dependency risks, test adequacy, rollback). Returns `PASS` / `PASS WITH RECOMMENDATIONS` / `BLOCK`. `BLOCK` gates the test run. Same re-classification escape hatch.
- **`agents/test-baseline.md`** — moved from `plugins/workflow-tools/skills/` then briefly `plugins/workflow-tools/agents/` to the repo's top-level `agents/` in the round-3 restructure. Same behaviour, now installed at `~/.claude/agents/test-baseline.md` as a user-level subagent.
- **`references/model-routing/classification.md`** — single source of truth for the four complexity levels, the triggers, the routing rules, and the eight review dimensions. All three commands link to it.
- **`tests/smoke.sh`** — install → uninstall → install smoke test in a throwaway `HOME`. Covers the full install, the subtractive `--no-hooks` path, `uninstall.sh`, JSON validity of `settings-additions.json`, and agent-file frontmatter validation.
- **`uninstall.ps1`** — native Windows uninstaller (PowerShell). Mirrors `uninstall.sh`: removes managed symlinks/copies and strips hook entries from `settings.json` if Python is available.
- **`.gitignore`** — added `settings.local.json`, `settings-local.json`, `.claude/settings.local.json` to prevent accidental commit of Claude Code machine-specific overrides.

### Changed in commands
- **`/impl`** — new Phase 1.5 classification step; `SIGNIFICANT` / `HIGH-RISK` plans go through `workflow-tools:risk-planner`, implementation stays on the current model or Sonnet, then `workflow-tools:code-review` runs before tests. Phase 4/5 now include the classification and the review verdict.
- **`/vuln`** — step 5 classifies each CVE based on the actual change required (same-major patch/minor bump → `MODERATE`; major bump or API-break → `SIGNIFICANT` / `HIGH-RISK`). `MODERATE` keeps the existing flow; `SIGNIFICANT` / `HIGH-RISK` delegate planning to Opus, review the fix with Opus, and gate tests on the verdict. Classification is included in the commit message and PR body.
- **`/upgrade`** — Phase 1 step 5 classifies each component. `MODERATE` components follow the existing apply → build → test path. `SIGNIFICANT` / `HIGH-RISK` components plan with Opus (Phase 1 step 8) and get an Opus review before build/test (Phase 2 step 6). The summary table gains `Class` and `Review` columns.

### Changed in hooks
- **`preload-context.sh`** — injects a one-line model-routing reminder before the existing git context for `/impl`, `/vuln`, `/upgrade`. Points at `references/model-routing/classification.md` so the rules are one read away.

### Fixed
- **Plugin agent declaration format.** The previous `plugin.json` "agents" array with a `"skill": "skills/X.md"` pointer was not a recognized Claude Code plugin format — Claude Code discovers plugin agents only from `agents/<name>.md` files with YAML frontmatter. Under the old layout, `"model": "opus"` was silently dropped and the subagents (including the pre-existing `test-baseline` from 1.0.0) never actually registered. Migrated all three agents to the canonical format and removed the old `skills/` directory. Invocation syntax (`subagent_type: "workflow-tools:<name>"`) is unchanged.
- **`/upgrade` risk-planner brief** — Phase 1 step 8 previously asked the planner to consume a "usage-site summary" that the earlier phases never produced. Now the brief passes only the data actually captured (inventory paths + Agent A's compat output) and delegates the usage-site grep to the planner, which has `Grep`/`Read`/`Glob` tools.
- **`/vuln` risk-planner brief** — same fix. Detect agent returns declaration paths, not import sites; the brief no longer overstates the summary, and the planner does its own blast-radius scan.
- **Re-classification escape hatch now handled by callers.** The Opus `risk-planner` and `code-review` skills can return a `### Re-classification` section when they decide on inspection that the task is actually `SIMPLE` / `MODERATE`. Previously none of the three callers recognised this return shape — they expected a full plan / PASS-BLOCK-etc. verdict and would stall. `/impl`, `/vuln`, `/upgrade` now detect the re-classification, confirm with the user (accept / override / cancel), and fall back to the non-Opus path when accepted. The re-review on later fix deltas is skipped once a run has been down-classified.
- **`README.md` `/upgrade` example table** — missing `Class` and `Review` columns that `commands/upgrade.md` specifies. Realigned so the README matches the command's actual output format.
- **Agent skills cite classification rules by absolute path.** `agents/risk-planner.md` and `agents/code-review.md` now reference `~/.claude/claude-config/references/model-routing/classification.md` with the absolute path; the agents' working directory is the caller's project, not this repo, so relative paths wouldn't resolve.
- **`/impl` Phase 2B "Revise" branch** — now explicitly requires the re-invocation to re-send the full risk-planner brief with the additional constraint merged in, not a delta. `risk-planner` refuses to plan on an incomplete brief.
- **`preload-context.sh` regex tightened** — now requires at least one non-whitespace non-hyphen argument so bare `/impl` or `/impl --help` no longer triggers a context injection.
- **Classification threshold made exclusive** — file-count rule was `more than 3-5` on SIGNIFICANT and `fewer than 3-5` on MODERATE, which both matched at exactly 4. Pinned to `4 or more` for SIGNIFICANT and `3 or fewer` for MODERATE.
- **`agents/test-baseline.md` Makefile parse row** — previously detected `make test` but had no parse pattern; a Make-driven project would get `Total: 0 | Passing: 0 | Failing: 0` silently. The parse table now has a Make row with best-effort pattern matching and a note explaining the limitation.
- **`tests/smoke.sh` regression guard** — `--no-plugin` now explicitly asserts that hook entries survive in `settings.json`. A regression that accidentally strips hooks when `--no-plugin` runs would previously pass.
- **Agents never actually registered — replaced with a robust invocation pattern.** Round-3 empirical testing revealed that neither the previous `plugins/workflow-tools/` layout (which required marketplace registration + `installed_plugins.json` + `enabledPlugins`) nor the immediately-tried `agents/*.md` user-level layout (which requires Claude Code to re-scan at session start) could be invoked via `Agent(subagent_type: "workflow-tools:<name>")` or `Agent(subagent_type: "<name>")` in the session that installed them. Two earlier CHANGELOG rounds of fixes papered over this at the static-correctness level but the routing was a no-op throughout. **Fix:** the three commands now invoke the agents via `Agent(subagent_type: "general-purpose", model: "opus", prompt: "Read and adopt ~/.claude/agents/<name>.md, then [brief]")`. The `model` argument on the `Agent` tool itself forces Opus for the two Opus agents regardless of discovery. The agent files are still installed at `~/.claude/agents/` so future Claude Code versions with solid user-agent discovery can invoke them directly. Verified empirically in-session.
- **`plugins/` layout retired.** `plugins/workflow-tools/plugin.json` and all of `plugins/workflow-tools/agents/*.md` moved to `agents/*.md` at the repo root. The old `plugins/` directory is deleted. `install.sh` / `install.ps1` symlink each agent individually into `~/.claude/agents/`, same pattern used for `commands/`. The installer also removes any legacy `~/.claude/plugins/workflow-tools` symlink on upgrade and drops the empty `~/.claude/plugins/` parent if nothing else lives there.
- **`--no-plugin` flag removed from both installers.** There is no plugin any more. The subagents are required by `/vuln`, `/upgrade`, and the Opus-gated `/impl` flow — there is no opt-out.
- **`tests/smoke.sh` rewritten for the new layout.** 54 assertions: new agent-file frontmatter checks, new per-agent symlink checks in all install/uninstall phases, a check that `--no-plugin` is now rejected as an unknown flag, and a legacy-cleanup test that drops a stale `plugins/workflow-tools` symlink before install and asserts it's removed.

### Changed
- **`install.sh --no-hooks` / `--no-plugin` now actively remove** previously-installed components rather than silently leaving them in place. Running `install.sh --no-hooks` after a full install removes the hook symlinks and strips the hook entries from `settings.json`. This matches what users expect from the flag name.
- **`uninstall.sh` and `uninstall.ps1` symlink matching tightened** — require a path-segment boundary (`/claude-config/` rather than a loose substring) so unrelated paths like `claude-config-backup` can't be matched.
- **README** — surfaces the Windows installation path from the main "Install" section (previously only reachable by scrolling to the Windows section); adds the native Windows uninstall command to the Uninstall section; documents update workflow for Windows.

### Fixed
- **`install.ps1` / `uninstall.ps1`** — removed PowerShell 7+ only operators (`||`, `??`) that broke on Windows PowerShell 5.1 (the default on Windows 10/11). Replaced with PS5.1-compatible forms.
- **`install.ps1` / `uninstall.ps1`** — replaced em-dashes and box-drawing characters with ASCII. Windows PowerShell 5.1 reads script files without a BOM using the ANSI code page, which mangled UTF-8 multi-byte sequences and caused parser errors at every line with fancy characters.
- **`uninstall.ps1`** — probe Python with a real `--version` call before using it, so the Windows Store `python3.exe` stub (a placeholder that errors at runtime) is correctly identified as "not Python" and the script prints a helpful skip-message instead of a red error.

### Verified
- End-to-end install and uninstall on Windows with both Windows PowerShell 5.1 and PowerShell 7.6.1. PS 5.1 falls back to file copies (no Dev Mode / admin); PS 7.6.1 successfully creates symlinks. Round-trip install → uninstall → install works cleanly on both.

## [1.1.0] — 2026-04-24

### Added
- **`uninstall.sh`** — idempotent reverse of `install.sh`; removes managed symlinks and strips our hook entries from `~/.claude/settings.json`.
- **`install.sh --no-hooks` / `--no-plugin` / `--help`** flags for granular installs.
- **`install.ps1`** — native Windows installer (PowerShell). Creates symlinks with auto-fallback to file copy when Developer Mode / admin isn't available. Skips hooks (bash-only).
- **`references/fix-vuln/`** and **`references/upgrade/`** — reference docs for `/vuln` and `/upgrade` are now vendored into the repo (previously external at `~/.copilot/skills/`).
- **`CHANGELOG.md`** — this file.

### Changed
- **Hook field names corrected**: `preload-context.sh` now reads the `prompt` field (with `user_prompt`/`message` fallbacks) from the UserPromptSubmit payload; `test-notify.sh` now reads `tool_input.command` and `tool_response.output` (with top-level fallbacks) from the PostToolUse payload. Both hooks were previously silently exiting early due to reading the wrong fields.
- **`preload-context.sh` hardening** — removed `set -euo pipefail`, added `python3` availability guard, error-tolerant command substitution. Matches the robustness of `test-notify.sh`.
- **`/impl` step 8 agents** now receive a structured change summary block (including `git diff --stat` output and notable additions/removals) instead of a one-sentence description. Documentation, knowledge, and instructions agents can now reason precisely about what changed.
- **`install.sh` location guard** — refuses to run unless located at `$HOME/.claude/claude-config/`. Prevents silent misconfiguration when the repo is cloned elsewhere.
- **`install.sh` plugin symlink** — now unconditionally `rm -rf`s the target before `ln -sf`, preventing the "stray nested symlink" bug that occurred on repeated runs.
- **`install.sh` settings.json guard** — creates an empty `{}` skeleton if `~/.claude/settings.json` doesn't exist, rather than crashing.
- **`test-notify.sh` output parsing** — uses `python3` for framework output parsing (portable) instead of `grep -oP` (GNU-only, fails on macOS).
- **`/vuln` intro** — clarified the sequential-then-parallel execution model.
- **`/upgrade` Phase 2 step 3** — excludes `.github/workflows/` to prevent GitHub Actions from being processed twice.
- **README** — added detailed per-command phase explanations, Windows section, uninstall instructions, install-flag table.

## [1.0.0] — 2026-04-24

Initial shareable repo.

### Added
- **`commands/impl.md`** — `/impl` command with Explore subagent before planning and three parallel post-implementation agents (Documentation / Knowledge / Instructions).
- **`commands/vuln.md`** — `/vuln` command with parallel NVD / Detect / Baseline research before fix.
- **`commands/upgrade.md`** — `/upgrade` command with parallel compatibility research and GitHub Actions agents in Phase 1; uses `workflow-tools:test-baseline` for the test baseline.
- **`plugins/workflow-tools/`** — plugin with the reusable `test-baseline` agent (Maven / Gradle / npm / pytest / Makefile detection).
- **`hooks/notify-done.sh`** — Stop hook; cross-platform desktop notification (macOS / Linux / WSL2 fallback chain).
- **`hooks/preload-context.sh`** — UserPromptSubmit hook; injects git branch/status/log for `/impl` / `/vuln` / `/upgrade`.
- **`hooks/test-notify.sh`** — PostToolUse:Bash hook; parses test output and notifies.
- **`install.sh`** — idempotent installer; `ln -sf` symlinks + Python JSON merge.
- **`settings-additions.json`** — hook entries merged into `~/.claude/settings.json`.
- **`README.md`** — setup, usage, and platform notes.
- **`docs/specs/2026-04-24-command-subagents-hooks-design.md`** — design document.
