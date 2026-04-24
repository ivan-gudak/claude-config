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

# ── Repo layout + JSON validity ──────────────────────────────────────────────
section "Repo layout + JSON validity"
if command -v python3 &>/dev/null; then
    if python3 -c "import json; json.load(open('$REPO_DIR/settings-additions.json'))"; then
        ok "settings-additions.json parses"
    else
        bad "settings-additions.json does NOT parse"
    fi

    # Every agent file exists at the canonical location with required frontmatter.
    # Agent discovery in Claude Code works via ~/.claude/agents/<name>.md — the
    # installer symlinks each one. The repo source lives at <repo>/agents/.
    for agent in test-baseline risk-planner code-review; do
        if python3 -c "
import sys
p = '$REPO_DIR/agents/$agent.md'
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
# Filename must match the frontmatter 'name' field (Claude Code convention).
want_name = 'name: ' + '$agent'
if want_name not in front:
    print('name mismatch')
    sys.exit(1)
# risk-planner and code-review must declare model: opus
if '$agent' in ('risk-planner', 'code-review') and 'model: opus' not in front:
    print('no model: opus')
    sys.exit(1)
sys.exit(0)
"; then
            ok "agents/$agent.md has valid frontmatter (name, tools, model where required)"
        else
            bad "agents/$agent.md frontmatter is invalid or missing"
        fi
    done

    # The legacy plugin layout must not be present in the repo any more.
    if [[ -d "$REPO_DIR/plugins" ]]; then
        bad "legacy plugins/ directory still present in the repo — should be deleted"
    else
        ok "legacy plugins/ directory absent from the repo"
    fi
else
    ok "python3 unavailable — JSON / frontmatter checks skipped"
fi

# ── Full install ─────────────────────────────────────────────────────────────
section "Full install"
bash "$FAKE_REPO/install.sh" >/dev/null

for cmd in impl.md vuln.md upgrade.md; do
    assert_symlink "$FAKE_CLAUDE/commands/$cmd" "commands/$cmd symlink"
done
for agent in test-baseline.md risk-planner.md code-review.md; do
    assert_symlink "$FAKE_CLAUDE/agents/$agent" "agents/$agent symlink"
done
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_symlink "$FAKE_CLAUDE/hooks/$hook" "hooks/$hook symlink"
done
assert_settings_has_hook "notify-done.sh"    "settings.json contains notify-done hook"
assert_settings_has_hook "preload-context.sh" "settings.json contains preload-context hook"
assert_settings_has_hook "test-notify.sh"    "settings.json contains test-notify hook"
# Installer must not leave a stale plugins/ dir behind after the legacy cleanup.
assert_missing "$FAKE_CLAUDE/plugins/workflow-tools" "no legacy plugins/workflow-tools on install target"

# ── Idempotent re-run ────────────────────────────────────────────────────────
section "Idempotent re-run"
bash "$FAKE_REPO/install.sh" >/dev/null
for cmd in impl.md vuln.md upgrade.md; do
    assert_symlink "$FAKE_CLAUDE/commands/$cmd" "re-run keeps commands/$cmd"
done
for agent in test-baseline.md risk-planner.md code-review.md; do
    assert_symlink "$FAKE_CLAUDE/agents/$agent" "re-run keeps agents/$agent"
done

# ── Subtractive: --no-hooks removes hooks + strips settings ──────────────────
section "--no-hooks subtractive"
bash "$FAKE_REPO/install.sh" --no-hooks >/dev/null
for hook in notify-done.sh preload-context.sh test-notify.sh; do
    assert_missing "$FAKE_CLAUDE/hooks/$hook" "hooks/$hook removed by --no-hooks"
done
assert_settings_lacks_hook "notify-done.sh"    "--no-hooks stripped notify-done from settings.json"
assert_settings_lacks_hook "preload-context.sh" "--no-hooks stripped preload-context from settings.json"
assert_settings_lacks_hook "test-notify.sh"    "--no-hooks stripped test-notify from settings.json"
# Commands + agents remain
assert_symlink "$FAKE_CLAUDE/commands/impl.md"   "--no-hooks keeps commands/impl.md"
for agent in test-baseline.md risk-planner.md code-review.md; do
    assert_symlink "$FAKE_CLAUDE/agents/$agent"  "--no-hooks keeps agents/$agent"
done

# ── --no-plugin flag must be rejected (agents are now essential) ─────────────
section "--no-plugin flag retired"
if bash "$FAKE_REPO/install.sh" --no-plugin >/dev/null 2>&1; then
    bad "--no-plugin should be rejected as an unknown flag"
else
    ok "--no-plugin is rejected (agents are not optional)"
fi

# ── Uninstall ────────────────────────────────────────────────────────────────
section "Uninstall"
bash "$FAKE_REPO/install.sh" >/dev/null          # restore full install first
bash "$FAKE_REPO/uninstall.sh" >/dev/null
for cmd in impl.md vuln.md upgrade.md; do
    assert_missing "$FAKE_CLAUDE/commands/$cmd" "uninstall removed commands/$cmd"
done
for agent in test-baseline.md risk-planner.md code-review.md; do
    assert_missing "$FAKE_CLAUDE/agents/$agent" "uninstall removed agents/$agent"
done
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
for agent in test-baseline.md risk-planner.md code-review.md; do
    assert_symlink "$FAKE_CLAUDE/agents/$agent" "round-trip: agents/$agent back"
done

# ── Legacy plugin cleanup on install ─────────────────────────────────────────
# If a user upgrades from an older install (plugins/workflow-tools symlink
# existed), a fresh install.sh must remove that stale symlink so ~/.claude/plugins
# doesn't linger as a broken directory.
section "Legacy plugin cleanup on upgrade"
bash "$FAKE_REPO/uninstall.sh" >/dev/null
mkdir -p "$FAKE_CLAUDE/plugins"
ln -s "../claude-config/plugins/workflow-tools-phantom" "$FAKE_CLAUDE/plugins/workflow-tools"  # stale
bash "$FAKE_REPO/install.sh" >/dev/null
assert_missing "$FAKE_CLAUDE/plugins/workflow-tools" "install cleaned up legacy plugins/workflow-tools"

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n-- %d passed, %d failed --\n' "$pass" "$fail"
if (( fail > 0 )); then
    exit 1
fi
exit 0
