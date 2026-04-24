# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A distributable Claude Code configuration: three slash commands (`/impl`, `/vuln`, `/upgrade`), a reusable `workflow-tools` plugin (with the `test-baseline` agent), and three hooks. No application code, no test suite — this is installed into `~/.claude/` via `install.sh` / `install.ps1`.

## Install / uninstall workflow

```bash
# macOS / Linux / WSL2 — idempotent, safe to re-run after every `git pull`
bash install.sh                 # full install
bash install.sh --no-hooks      # commands + plugin only; also ACTIVELY REMOVES hooks if previously installed
bash install.sh --no-plugin     # commands + hooks only
bash uninstall.sh               # full removal

# Native Windows (no hooks — bash-only)
powershell -ExecutionPolicy Bypass -File install.ps1
powershell -ExecutionPolicy Bypass -File install.ps1 -UseCopy   # force copy instead of symlink
powershell -ExecutionPolicy Bypass -File install.ps1 -NoPlugin
powershell -ExecutionPolicy Bypass -File uninstall.ps1
```

There is no test suite. Changes are verified end-to-end by running install → uninstall → install on target platforms and confirming symlinks, `settings.json` merges, and hook behaviour.

## Architecture

Three layers, all linked into `~/.claude/` by the installer so Claude Code discovers them:

- **`commands/*.md`** — slash-command prompts. Each is a structured workflow (phases, invariants, parallel agent spawns). `$ARGUMENTS` holds user input; `@path/to/file` syntax reads a spec file as the argument.
- **`plugins/workflow-tools/`** — a plugin declared by `plugin.json` (manifest only) with agents defined in `plugins/workflow-tools/agents/*.md` using YAML frontmatter (per the Claude Code plugin spec). Three agents: `test-baseline` (captures a pre-change test baseline for regression comparison; inherits session model), `risk-planner` (Opus; deep risk-weighted plan for SIGNIFICANT/HIGH-RISK tasks), `code-review` (Opus; 8-dimension post-implementation review that gates the test run). All are invoked by fully-qualified subagent_type (e.g. `workflow-tools:risk-planner`). The earlier `skills/*.md` layout was removed — it wasn't recognized by Claude Code, so agents silently never registered.
- **`hooks/*.sh`** — `notify-done.sh` (Stop), `preload-context.sh` (UserPromptSubmit), `test-notify.sh` (PostToolUse:Bash). Registered in `~/.claude/settings.json` by merging `settings-additions.json`.

`references/fix-vuln/` and `references/upgrade/` vendor reference docs consumed by `/vuln` and `/upgrade` subagents (NVD API shape, build-system detection rules, LTS sources, ecosystem compatibility notes). Keep them updated when the commands' research logic changes.

## Installer invariants

These constraints are load-bearing — violating them silently breaks installs:

- **Location guard.** `install.sh` refuses to run unless `$SCRIPT_DIR`'s parent is exactly `$HOME/.claude`. The repo MUST live at `~/.claude/claude-config/`.
- **Relative symlink targets.** All symlinks use `../claude-config/...` (never absolute paths) so they resolve correctly inside containers that bind-mount `~/.claude/` from the host (e.g. ai-containers, Docker dev envs).
- **Plugin symlink is `rm -rf`'d before `ln -sf`.** Without this, a second `install.sh` run follows the existing symlink and creates a nested stray link inside it.
- **`--no-hooks` / `--no-plugin` are subtractive, not just skip-flags.** They actively remove previously-installed components and strip matching entries from `settings.json`. Any new optional component must implement both the add and the remove path.
- **`settings.json` merge is surgical.** The Python block in `install.sh` de-dupes by `(matcher, frozenset(commands))` — adding a hook entry means the `settings-additions.json` shape has to match exactly for re-runs to be idempotent.
- **Symlink removal matches `/claude-config/` as a path segment, not a substring.** Prevents `uninstall.sh` from touching unrelated paths like `claude-config-backup`.

## Windows / PowerShell compatibility

`install.ps1` and `uninstall.ps1` must run on **Windows PowerShell 5.1** (the default on Windows 10/11), not just PowerShell 7+. When editing them:

- **No PS7-only operators** — avoid `||`, `&&`, `??`, `?.`. Use `if`/`else` and `$null` checks.
- **ASCII only** — no em-dashes (`—`), en-dashes (`–`), or box-drawing characters. PS 5.1 reads BOM-less script files as ANSI, which mangles UTF-8 multi-byte sequences and causes parser errors at every offending line. Use `-`, `--`, or ASCII equivalents.
- **Symlink fallback to copy.** Without Developer Mode or admin rights, `New-Item -ItemType SymbolicLink` fails — both scripts auto-fall-back to `Copy-Item`. Preserve this path when adding new install targets. Note: with copies, users must re-run `install.ps1` after `git pull`; with symlinks, `git pull` alone is enough.
- **Probe `python` / `python3` before using.** On Windows, `python3.exe` can be the Microsoft Store stub that errors at runtime. `uninstall.ps1` calls `--version` first to confirm it's a real interpreter before using it to edit `settings.json`.

## Hook conventions

Hooks receive JSON on stdin from Claude Code. Field names matter — mis-reading them fails silently:

- **`preload-context.sh`** (UserPromptSubmit) reads the `prompt` field from the payload, with `user_prompt` / `message` as fallbacks for older schemas. It only injects git context when the prompt starts with `/impl`, `/vuln`, or `/upgrade`.
- **`test-notify.sh`** (PostToolUse:Bash) reads `tool_input.command` and `tool_response.output`, with top-level `command` / `output` as fallbacks. Parses test-runner output via `python3` (portable regex) — do not switch to `grep -oP` (GNU-only, fails on macOS).
- **Be tolerant of missing deps.** Guard `python3` and other optional commands with availability checks, use error-tolerant command substitution (`|| true` or `2>/dev/null`), and prefer exiting 0 on missing prerequisites over `set -euo pipefail` crashes. `preload-context.sh` was hardened this way in 1.1.0.

## Command authoring conventions

The three command files (`commands/impl.md`, `vuln.md`, `upgrade.md`) share a house style — when editing or adding commands, follow it:

- **Clarification uses `choices` arrays, never plain text.** The last choice in every array MUST be `"Other… (describe)"`. Recommended defaults are first and labelled `"(Recommended)"`.
- **Parallel subagent spawns happen in a single message.** `/impl` Phase 3 step 8 spawns three agents (Documentation / Knowledge / Instructions) at once; `/vuln` and `/upgrade` Phase 1 spawn research agents in parallel. Never serialize these.
- **Invocation of the plugin agent is by fully-qualified name**: `workflow-tools:test-baseline`.
- **Invariants live at the bottom of each command file.** Phrase them as `NEVER …` / `ALWAYS …` rules — these survive prompt drift better than inline reminders.

## Changelog discipline

`CHANGELOG.md` follows Keep a Changelog 1.1.0. Versioning is at the **repo** level (semver); plugin versions are tracked separately in `plugins/*/plugin.json`. Every user-visible behaviour change goes under `[Unreleased]` until a release is cut. The `/impl` command's Phase 3 step 8 Documentation agent is configured to update `CHANGELOG.md` automatically for user-facing changes — review its edits rather than duplicating them.
