# Command Subagents & Hooks Design

**Date:** 2026-04-24
**Status:** Approved
**Scope:** Global commands `/impl`, `/vuln`, `/upgrade`

---

## Goal

Optimize the three global workflow commands by introducing inline subagent calls for context isolation and parallelism, a shared `workflow-tools:test-baseline` plugin agent reusable across current and future commands, and three Claude Code hooks for notifications and context pre-loading.

---

## Architecture

The git repo lives at `~/.claude/claude-config/`. Symlinks within `~/.claude/` point into it, so both the host and any Docker container that mounts `~/.claude/` (as ai-containers does) see real files — no broken symlink risk. Works identically on macOS and Linux/WSL2.

```
~/.claude/
├── claude-config/              ← git repo (source of truth)
│   ├── README.md
│   ├── install.sh              ← idempotent; safe to re-run after git pull
│   ├── settings-additions.json ← hook entries to merge into settings.json
│   ├── commands/
│   │   ├── impl.md             ← +Explore subagent (Phase 2)
│   │   │                          +3 parallel subagents (Phase 3–4)
│   │   ├── vuln.md             ← +parallel NVD/detect subagents (steps 3–4)
│   │   │                          +workflow-tools:test-baseline (step 6)
│   │   └── upgrade.md          ← +compat-research subagent (Phase 1)
│   │                              +workflow-tools:test-baseline (Phase 2)
│   │                              +GH Actions subagent (parallel)
│   ├── plugins/
│   │   └── workflow-tools/
│   │       ├── plugin.json
│   │       └── skills/
│   │           └── test-baseline.md
│   ├── hooks/
│   │   ├── notify-done.sh      ← Stop hook (cross-platform)
│   │   ├── preload-context.sh  ← UserPromptSubmit hook
│   │   └── test-notify.sh      ← PostToolUse:Bash hook (cross-platform)
│   └── docs/specs/
│       └── 2026-04-24-command-subagents-hooks-design.md
│
│   (symlinks — all targets within ~/.claude/, work in Docker mounts)
├── commands/impl.md            → claude-config/commands/impl.md
├── commands/vuln.md            → claude-config/commands/vuln.md
├── commands/upgrade.md         → claude-config/commands/upgrade.md
├── plugins/workflow-tools/     → claude-config/plugins/workflow-tools/
├── hooks/notify-done.sh        → claude-config/hooks/notify-done.sh
├── hooks/preload-context.sh    → claude-config/hooks/preload-context.sh
├── hooks/test-notify.sh        → claude-config/hooks/test-notify.sh
└── settings.json               ← hook entries merged by install.sh
```

**Key constraints:**
- All subagents except `test-baseline` are inline Agent calls — prompts live in the command files
- Commands remain self-contained — they work without hooks configured (hooks are enhancements, not dependencies)
- Hooks are side-effects only — orchestration logic stays in the command prompts, never in hooks
- Subagent-to-subagent handover is expressed in command prompt language, not hook events

---

## 1. workflow-tools Plugin

### Files

**`~/.claude/plugins/workflow-tools/plugin.json`**
```json
{
  "name": "workflow-tools",
  "version": "1.0.0",
  "description": "Reusable workflow agents for command pipelines",
  "agents": [{
    "name": "test-baseline",
    "description": "Run the full test suite and return structured results for regression comparison. Use before making changes to capture a baseline.",
    "skill": "skills/test-baseline.md",
    "tools": ["Bash", "Read", "Glob", "LS"]
  }]
}
```

### test-baseline Agent

**Purpose:** Run the project's full test suite, parse results, return a structured summary suitable for before/after regression comparison. Reusable by any command that makes changes and needs to verify no regressions.

**Steps:**

1. **Detect framework** — scan for build/config files in order:
   - `pom.xml` → Maven (`mvn test`)
   - `build.gradle` / `build.gradle.kts` → Gradle (`./gradlew test` or `gradle test`)
   - `package.json` → read `scripts.test` field
   - `pyproject.toml` / `setup.py` / `pytest.ini` → pytest (`pytest`)
   - `Makefile` with a `test` target → `make test`
   - If none found: return a clear warning and empty baseline — never silently skip

2. **Run** — execute the detected command with up to 10-minute timeout. Pre-existing failures are valid baseline data — record them without judgment.

3. **Return this exact structure:**

```markdown
## Test Baseline
- **Framework**: [name]
- **Command**: `[command]`
- **Total**: [n] | **Passing**: [n] | **Failing**: [n] | **Skipped**: [n]

### Pre-existing failures
[list of test identifiers, or "none"]

### Passing tests
[list of all passing test identifiers]
```

**Calling convention in command files:**
```
Use the Agent tool with subagent_type "workflow-tools:test-baseline".
Pass the project root as context. Store the returned baseline for later comparison.
```

The "Passing tests" list is what calling commands use for regression detection — after a change, re-run the agent and diff the two passing lists. Pre-existing failures are clearly labelled so callers don't treat them as regressions.

---

## 2. Command Modifications

### /impl

**Phase 2 — Explore subagent before planning**

Before writing the implementation plan, spawn an `Explore` subagent with the implementation description. Returns a structured file map (relevant files, existing patterns, test structure, naming conventions). Claude uses that summary to plan — Read/Grep/Glob traces never touch the main context.

```
[Phase 2 start — before "Produce a written implementation plan"]
→ Spawn Explore subagent:
    "Given this description: [X], find: relevant source files,
     existing patterns and conventions, test file locations,
     naming conventions. Return a structured summary."
→ Use returned summary as codebase context for the plan
```

Estimated token savings: 3–8K per run.

**Phase 3 step 8 + Phase 4 — three parallel subagents**

After implementation is verified, replace the current sequential doc/knowledge/instructions steps with three parallel agents spawned in a single message:

```
[After step 7 — implementation verified]
→ Spawn in parallel:
  Agent 1 (general-purpose):
    "Scan for README.md, CHANGELOG.md, docs/ in [project root].
     The implementation was: [summary]. Determine if docs need updating
     (skip for bug fixes / internal refactors). If yes, apply minimal edits."

  Agent 2 (general-purpose):
    "Check ~/.claude/memory/ and .claude/memory/ for existing knowledge files.
     The implementation was: [summary]. Determine if a new knowledge entry is
     warranted. If yes, append using the standard entry format."

  Agent 3 (general-purpose):
    "Check CLAUDE.md (project) and ~/.claude/CLAUDE.md (global).
     The implementation was: [summary]. Determine if any rules, guidance, or
     guardrails are missing. If yes, apply minimal additive changes only."

→ Collect three summaries → feed into Phase 5 report
```

Phase 5 report gains a `### Documentation` field (already added to the command file).

---

### /vuln

**Steps 3–5 — parallel research per CVE + test-baseline**

Replace the sequential NVD lookup → library detect → baseline with parallel agents. For N CVEs, research agents scale to N parallel pairs.

```
[Before any fixes — after parsing all CVE tokens]
→ Spawn in parallel:
  For each CVE:
    Agent A-n (WebFetch/WebSearch):
      "Look up [CVE-ID] on NVD API. Return: affected package name,
       vulnerable version range, minimum safe version, one-line description."

    Agent B-n (Explore):
      "Scan the repository for [package name from CVE]. Check build files
       (pom.xml, build.gradle, package.json, requirements.txt). Return:
       current version in use, file(s) where it appears."

  Agent C (workflow-tools:test-baseline):
    Run test baseline — returns structured result for step 9 comparison.

→ Merge all results: CVE details + library locations + baseline
→ Proceed to fix sequentially per CVE
```

**Step 6** — removed (replaced by Agent C above, which runs earlier in parallel).

**Step 9** — unchanged, runs inline: diffs the Agent C baseline against post-fix test run.

---

### /upgrade

**Phase 1 — two parallel subagents**

Replace the inline compatibility research + GitHub Actions scan with parallel agents:

```
[Phase 1 start — after inventory/version resolution]
→ Spawn in parallel:
  Agent A (WebFetch/WebSearch):
    "For each component being upgraded: [list with current → target versions].
     Fetch release notes and changelogs. Return per component:
     - Known breaking changes
     - Required companion upgrades (e.g. Spring Boot → Hibernate)
     - Compatibility with other components in this upgrade set
     - Any Java/Node/Python runtime version requirements"

  Agent B (Bash/Read/Edit) [only if .github/workflows/ exists]:
    "Scan all .yml/.yaml files in .github/workflows/.
     For each 'uses: owner/action@ref', fetch the latest release tag via:
     gh api repos/<owner>/<action>/releases/latest --jq .tag_name
     Apply updates. Return: list of actions updated, any major version bumps flagged."

→ Merge reports → present upgrade plan to user for confirmation
```

**Phase 2 step 1** — replaced by `workflow-tools:test-baseline`:

```
[Phase 2 start — first component only]
→ Use Agent tool with subagent_type "workflow-tools:test-baseline"
→ Store baseline — reuse for all subsequent component comparisons
```

**Parallelism summary:**

| Command | Before | After |
|---------|--------|-------|
| `/impl` | explore → plan → implement → doc → knowledge → instructions | explore; then implement; then doc ∥ knowledge ∥ instructions |
| `/vuln` | NVD → detect → baseline → fix | (NVD ∥ detect ∥ baseline) → fix |
| `/upgrade` | research → GH Actions → baseline → apply | (research ∥ GH Actions); then baseline → apply |

---

## 3. Hooks

All scripts live in `~/.claude/hooks/`. All scripts exit 0 on any error — they never block Claude.

### Hook 1 — `notify-done.sh` (Stop)

Fires at the end of every Claude turn. Useful for all long-running commands.

**Logic:**
```bash
#!/usr/bin/env bash
message="Claude Code finished"

if [[ "$OSTYPE" == "darwin"* ]]; then
    osascript -e "display notification \"$message\" with title \"Claude Code\""
elif grep -qi microsoft /proc/version 2>/dev/null; then
    wsl-notify-send --category "Claude Code" "$message" 2>/dev/null || \
    powershell.exe -Command \
      "Add-Type -AssemblyName System.Windows.Forms; \
       [System.Windows.Forms.NotifyIcon]::new() | Out-Null" 2>/dev/null || \
    echo -e '\a'
else
    notify-send "Claude Code" "$message" 2>/dev/null || echo -e '\a'
fi
```

**settings.json entry:**
```json
"Stop": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/notify-done.sh" }] }]
```

---

### Hook 2 — `preload-context.sh` (UserPromptSubmit)

Fires on every message submission. Exits immediately (near-zero overhead) if message doesn't match. If it matches `/impl`, `/vuln`, or `/upgrade`, injects git context before Claude starts processing — saving 2–4 tool calls per run.

**Logic:**
```bash
#!/usr/bin/env bash
# Read message from stdin JSON
message=$(python3 -c "import sys,json; print(json.load(sys.stdin).get('message',''))" 2>/dev/null)

if echo "$message" | grep -qE '^/(impl|vuln|upgrade)'; then
    echo "=== Auto-injected project context ==="
    if git rev-parse --git-dir > /dev/null 2>&1; then
        echo "Branch: $(git branch --show-current)"
        echo "Status:"; git status --short | head -20
        echo "Recent commits:"; git log --oneline -5
    else
        echo "(not a git repository)"
    fi
    echo "Directory:"; ls -1 | head -20
fi
```

**settings.json entry:**
```json
"UserPromptSubmit": [{ "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/preload-context.sh" }] }]
```

---

### Hook 3 — `test-notify.sh` (PostToolUse:Bash)

Fires after every Bash tool call. Detects test suite commands, parses results, notifies.

**Detected commands:** `mvn test`, `./gradlew test`, `gradle test`, `npm test`, `yarn test`, `pytest`, `make test`

**Result parsing per framework:**

| Framework | Pattern |
|-----------|---------|
| Maven | `Tests run: X, Failures: Y, Errors: Z` |
| Gradle | `X tests completed, Y failed` |
| pytest | `X passed, Y failed` |
| Jest/npm | `Tests: X passed, Y failed, Z total` |

**Logic:**
```bash
#!/usr/bin/env bash
input=$(cat)
command=$(echo "$input" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('command',''))" 2>/dev/null)
output=$(echo "$input"  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('output',''))"  2>/dev/null)

# Check if this was a test command
if ! echo "$command" | grep -qE '(mvn test|gradlew test|gradle test|npm test|yarn test|pytest|make test)'; then
    exit 0
fi

# Parse result (simplified — real script handles all frameworks)
summary=$(echo "$output" | grep -oE '([0-9]+ (passed|tests run|completed)[^,\n]*)' | head -1)
[[ -z "$summary" ]] && summary="tests completed"

message="Test run: $summary"

# Notify using platform-appropriate method (same chain as notify-done.sh)
if [[ "$OSTYPE" == "darwin"* ]]; then
    osascript -e "display notification \"$message\" with title \"Claude Code\""
elif grep -qi microsoft /proc/version 2>/dev/null; then
    wsl-notify-send --category "Claude Code" "$message" 2>/dev/null || echo -e '\a'
else
    notify-send "Claude Code" "$message" 2>/dev/null || echo -e '\a'
fi
```

**settings.json entry:**
```json
"PostToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "bash ~/.claude/hooks/test-notify.sh" }] }]
```

---

## Out of Scope

- Commands other than `/impl`, `/vuln`, `/upgrade`
- Hook-based subagent orchestration (handover logic stays in command prompts)
- Making any command dependent on hooks being present
- Plugin agents for phases other than `test-baseline`
- Notification customization (content, sound, persistence)

---

## Implementation Order

1. `workflow-tools` plugin (`plugin.json` + `test-baseline.md`) — dependency for steps 2 and 3
2. `/vuln` modifications — uses `test-baseline`
3. `/upgrade` modifications — uses `test-baseline`
4. `/impl` modifications — no plugin dependency
5. Hook scripts (`notify-done.sh`, `preload-context.sh`, `test-notify.sh`)
6. `settings.json` hook entries

---

## Repo & Installation

**Location:** `~/.claude/claude-config/` — inside `~/.claude/` so symlinks stay within the Docker-mounted directory.

**Context safety:** `~/.claude/` is Claude Code's config directory, not a project workspace. Claude does not auto-scan its contents during normal project work. README.md and other repo files in `~/.claude/claude-config/` cause zero token overhead.

**`install.sh` is idempotent** — safe to re-run after every `git pull`:
- Uses `ln -sf` for all symlinks (recreates existing, creates new — no breakage)
- Merges `settings-additions.json` into `~/.claude/settings.json` using a Python JSON merge that checks for existing hook entries before inserting — no duplicates on repeated runs
- Does not touch files in `~/.claude/` that are not managed by the repo

**Onboarding a new team member:**
```bash
cd ~/.claude
git clone <repo-url> claude-config
cd claude-config && ./install.sh
```

**Updating after a pull:**
```bash
cd ~/.claude/claude-config && git pull && ./install.sh
```

**Platform support:** macOS, Linux, WSL2 — no platform-specific branches in `install.sh` for the symlink/settings steps. Hook scripts (`notify-done.sh`, `test-notify.sh`) handle platform detection internally.

---

## Assumptions

- The user's Claude Code version supports `subagent_type` references to locally installed plugins
- `python3` is available in the shell environment (used by hooks to parse JSON stdin and by install.sh for settings merge)
- The `workflow-tools` plugin follows the same local plugin installation convention as other plugins in `~/.claude/plugins/`
