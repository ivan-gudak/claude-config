#!/usr/bin/env bash
# Installer smoke test. Exercises install.sh and uninstall.sh in a throwaway
# HOME so the user's real ~/.claude/ is not touched. Idempotent.
#
# Usage:
#   bash tests/smoke.sh
#
# Exits 0 on success, non-zero (with a FAIL line) on the first assertion miss.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_HOME="$(mktemp -d -t claude-config-smoke.XXXXXX)"
trap 'rm -rf "$TMP_HOME"' EXIT

# Work in an isolated HOME so install.sh's "expected directory" guard sees it
# at $TMP_HOME/.claude/claude-config/.
export HOME="$TMP_HOME"
FAKE_CLAUDE="$HOME/.claude"
FAKE_REPO="$FAKE_CLAUDE/claude-config"

mkdir -p "$FAKE_CLAUDE"
ln -s "$REPO_DIR" "$FAKE_REPO"

pass=0
fail=0

ok() { printf '  ok    %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  FAIL  %s\n' "$1" >&2; fail=$((fail + 1)); }

assert_symlink() {
    local path="$1" desc="$2"
    if [[ -L "$path" ]]; then ok "$desc"
    else bad "$desc (expected symlink at $path)"; fi
}

assert_missing() {
    local path="$1" desc="$2"
    if [[ ! -e "$path" && ! -L "$path" ]]; then ok "$desc"
    else bad "$desc (expected absent: $path)"; fi
}

assert_settings_has_hook() {
    local hook_cmd="$1" desc="$2"
    if ! command -v python3 &>/dev/null; then
        ok "$desc (python3 unavailable — skipped)"
        return
    fi
    local present
    present=$(python3 -c "
import json, sys
try:
    with open('$FAKE_CLAUDE/settings.json') as f:
        s = json.load(f)
    cmds = set()
    for _, entries in s.get('hooks', {}).items():
        for e in entries:
            for h in e.get('hooks', []):
                cmds.add(h.get('command', ''))
    print('yes' if any('$hook_cmd' in c for c in cmds) else 'no')
except Exception as exc:
    print('err:' + str(exc))
") || present="err"
    if [[ "$present" == "yes" ]]; then ok "$desc"
    else bad "$desc (settings.json probe: $present)"; fi
}

assert_settings_lacks_hook() {
    local hook_cmd="$1" desc="$2"
    if ! command -v python3 &>/dev/null; then
        ok "$desc (python3 unavailable — skipped)"
        return
    fi
    local present
    present=$(python3 -c "
import json, sys, os
path = '$FAKE_CLAUDE/settings.json'
if not os.path.exists(path):
    print('no')
    sys.exit(0)
try:
    with open(path) as f:
        s = json.load(f)
    cmds = set()
    for _, entries in s.get('hooks', {}).items():
        for e in entries:
            for h in e.get('hooks', []):
                cmds.add(h.get('command', ''))
    print('yes' if any('$hook_cmd' in c for c in cmds) else 'no')
except Exception as exc:
    print('err:' + str(exc))
") || present="err"
    if [[ "$present" == "no" ]]; then ok "$desc"
    else bad "$desc (settings.json probe: $present)"; fi
}

section() { printf '\n== %s ==\n' "$1"; }

# ── JSON validity ────────────────────────────────────────────────────────────
section "JSON validity"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('$REPO_DIR/plugins/workflow-tools/plugin.json'))"; then
        ok "plugin.json parses"
    else
        bad "plugin.json does NOT parse"
    fi
    if python3 -c "import json; json.load(open('$REPO_DIR/settings-additions.json'))"; then
        ok "settings-additions.json parses"
    else
        bad "settings-additions.json does NOT parse"
    fi
    # Sanity: plugin.json is manifest-only (agents live in agents/*.md per Claude Code spec)
    if python3 -c "
import json, sys
with open('$REPO_DIR/plugins/workflow-tools/plugin.json') as f:
    p = json.load(f)
# Fail if the old-style 'agents' array is back — it would be silently ignored by Claude Code.
sys.exit(1 if 'agents' in p else 0)
"; then
        ok "plugin.json is manifest-only (no stale 'agents' array)"
    else
        bad "plugin.json contains an 'agents' array — move them to agents/*.md with YAML frontmatter"
    fi
    # Every agent file has the required frontmatter fields
    for agent in test-baseline risk-planner code-review; do
        if python3 -c "
import sys
p = '$REPO_DIR/plugins/workflow-tools/agents/$agent.md'
try:
    with open(p) as f:
        src = f.read()
except FileNotFoundError:
    print('missing')
    sys.exit(1)
if not src.startswith('---'):
    sys.exit(1)
end = src.find('---', 3)
if end < 0:
    sys.exit(1)
front = src[3:end]
need = {'name:', 'description:', 'tools:'}
missing = [f for f in need if f not in front]
if missing:
    print('missing:', missing)
    sys.exit(1)
# risk-planner and code-review must declare model: opus
if '$agent' in ('risk-planner', 'code-review') and 'model: opus' not in front:
    print('no model: opus')
    sys.exit(1)
sys.exit(0)
"; then
            ok "agents/$agent.md has required frontmatter"
        else
            bad "agents/$agent.md is missing required frontmatter"
        fi
    done
else
    ok "python3 unavailable — JSON checks skipped"
fi

# ── Full install ─────────────────────────────────────────────────────────────
section "Full install"
bash "$FAKE_REPO/install.sh" >/dev/null

for cmd in impl.md vuln.md upgrade.md; do
    assert_symlink "$FAKE_CLAUDE/commands/$cmd" "commands/$cmd symlink"
done
assert_symlink "$FAKE_CLAUDE/plugins/workflow-tools" "plugins/workflow-tools symlink"
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_symlink "$FAKE_CLAUDE/hooks/$hook" "hooks/$hook symlink"
done
assert_settings_has_hook "notify-done.sh"    "settings.json contains notify-done hook"
assert_settings_has_hook "preload-context.sh" "settings.json contains preload-context hook"
assert_settings_has_hook "test-notify.sh"    "settings.json contains test-notify hook"

# ── Sanity: the plugin symlink exposes the agent files ──────────────────────
section "Plugin content reachable through symlink"
for agent in test-baseline.md risk-planner.md code-review.md; do
    if [[ -f "$FAKE_CLAUDE/plugins/workflow-tools/agents/$agent" ]]; then
        ok "agents/$agent reachable"
    else
        bad "agents/$agent NOT reachable through plugin symlink"
    fi
done
# Old layout must be absent
if [[ -d "$FAKE_CLAUDE/plugins/workflow-tools/skills" ]]; then
    bad "legacy skills/ directory still present — should have been removed in the migration"
else
    ok "legacy skills/ directory is absent"
fi

# ── Idempotent re-run ────────────────────────────────────────────────────────
section "Idempotent re-run"
bash "$FAKE_REPO/install.sh" >/dev/null
for cmd in impl.md vuln.md upgrade.md; do
    assert_symlink "$FAKE_CLAUDE/commands/$cmd" "re-run keeps commands/$cmd"
done
assert_symlink "$FAKE_CLAUDE/plugins/workflow-tools" "re-run keeps plugin symlink"
# No stray nested symlink inside the plugin link
if [[ -L "$FAKE_CLAUDE/plugins/workflow-tools/workflow-tools" ]]; then
    bad "stray nested symlink inside plugins/workflow-tools"
else
    ok "no stray nested plugin symlink"
fi

# ── Subtractive: --no-hooks removes hooks + strips settings ──────────────────
section "--no-hooks subtractive"
bash "$FAKE_REPO/install.sh" --no-hooks >/dev/null
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_missing "$FAKE_CLAUDE/hooks/$hook" "hooks/$hook removed by --no-hooks"
done
assert_settings_lacks_hook "notify-done.sh"    "--no-hooks stripped notify-done from settings.json"
assert_settings_lacks_hook "preload-context.sh" "--no-hooks stripped preload-context from settings.json"
assert_settings_lacks_hook "test-notify.sh"    "--no-hooks stripped test-notify from settings.json"
# Commands + plugin remain
assert_symlink "$FAKE_CLAUDE/commands/impl.md"           "--no-hooks keeps commands/impl.md"
assert_symlink "$FAKE_CLAUDE/plugins/workflow-tools"     "--no-hooks keeps plugin"

# ── Subtractive: --no-plugin removes the plugin ──────────────────────────────
section "--no-plugin subtractive"
# Re-install cleanly first to restore hooks for later checks
bash "$FAKE_REPO/install.sh" >/dev/null
bash "$FAKE_REPO/install.sh" --no-plugin >/dev/null
assert_missing "$FAKE_CLAUDE/plugins/workflow-tools" "plugin removed by --no-plugin"
assert_symlink "$FAKE_CLAUDE/commands/impl.md" "--no-plugin keeps commands/impl.md"
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_symlink "$FAKE_CLAUDE/hooks/$hook" "--no-plugin keeps hooks/$hook"
done
# Regression guard: --no-plugin must NOT touch hook entries in settings.json.
assert_settings_has_hook "notify-done.sh"    "--no-plugin keeps notify-done in settings.json"
assert_settings_has_hook "preload-context.sh" "--no-plugin keeps preload-context in settings.json"
assert_settings_has_hook "test-notify.sh"    "--no-plugin keeps test-notify in settings.json"

# ── Uninstall ────────────────────────────────────────────────────────────────
section "Uninstall"
bash "$FAKE_REPO/install.sh" >/dev/null          # restore full install first
bash "$FAKE_REPO/uninstall.sh" >/dev/null
for cmd in impl.md vuln.md upgrade.md; do
    assert_missing "$FAKE_CLAUDE/commands/$cmd" "uninstall removed commands/$cmd"
done
assert_missing "$FAKE_CLAUDE/plugins/workflow-tools" "uninstall removed plugin"
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_missing "$FAKE_CLAUDE/hooks/$hook" "uninstall removed hooks/$hook"
done
assert_settings_lacks_hook "notify-done.sh"    "uninstall stripped notify-done from settings.json"
assert_settings_lacks_hook "preload-context.sh" "uninstall stripped preload-context from settings.json"
assert_settings_lacks_hook "test-notify.sh"    "uninstall stripped test-notify from settings.json"

# ── Re-install after uninstall (round trip) ──────────────────────────────────
section "Re-install after uninstall (round trip)"
bash "$FAKE_REPO/install.sh" >/dev/null
for cmd in impl.md vuln.md upgrade.md; do
    assert_symlink "$FAKE_CLAUDE/commands/$cmd" "round-trip: commands/$cmd back"
done
assert_symlink "$FAKE_CLAUDE/plugins/workflow-tools" "round-trip: plugin back"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n-- %d passed, %d failed --\n' "$pass" "$fail"
if (( fail > 0 )); then
    exit 1
fi
exit 0
