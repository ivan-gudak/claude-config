#!/usr/bin/env bash
# Reverse of install.sh — remove managed symlinks and strip hook entries from settings.json.
# Idempotent: safe to re-run. Only touches what install.sh created.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_CLAUDE_DIR="$HOME/.claude"

if [[ "$CLAUDE_DIR" != "$EXPECTED_CLAUDE_DIR" ]]; then
    printf 'ERROR: uninstall.sh must run from within %s/claude-config/\n' "$EXPECTED_CLAUDE_DIR" >&2
    exit 1
fi

printf 'Uninstalling claude-config from %s\n' "$CLAUDE_DIR"

# ── Remove managed symlinks ───────────────────────────────────────────────────
# Only remove if the file is a symlink AND points into claude-config/.
# This prevents accidentally deleting unrelated files at the same path.

remove_if_our_symlink() {
    local link="$1"
    if [[ -L "$link" ]]; then
        local target
        target=$(readlink "$link")
        # Require a path-segment boundary so targets like "claude-config-backup/..."
        # are not mistakenly matched.
        if [[ "$target" == *"/claude-config/"* || "$target" == "../claude-config/"* ]]; then
            rm -f "$link"
            printf '  removed %s\n' "$link"
        else
            printf '  skipped %s (symlink points outside claude-config)\n' "$link"
        fi
    fi
}

for cmd in impl.md vuln.md upgrade.md; do
    remove_if_our_symlink "$CLAUDE_DIR/commands/$cmd"
done

for agent in test-baseline.md risk-planner.md code-review.md review-fixer.md impl-maintenance.md; do
    remove_if_our_symlink "$CLAUDE_DIR/agents/$agent"
done

# Legacy plugin symlink cleanup — harmless if already gone.
remove_if_our_symlink "$CLAUDE_DIR/plugins/workflow-tools"
# Drop empty plugins/ dir left behind from the legacy layout.
if [[ -d "$CLAUDE_DIR/plugins" ]] && [[ -z "$(ls -A "$CLAUDE_DIR/plugins" 2>/dev/null)" ]]; then
    rmdir "$CLAUDE_DIR/plugins" 2>/dev/null || true
fi

for hook in notify-done.sh preload-context.sh test-notify.sh; do
    remove_if_our_symlink "$CLAUDE_DIR/hooks/$hook"
done

# ── Strip our hook entries from settings.json ─────────────────────────────────

if [[ ! -f "$CLAUDE_DIR/settings.json" ]]; then
    printf '  settings.json not found — nothing to clean up\n'
else
    python3 - "$CLAUDE_DIR/settings.json" "$SCRIPT_DIR/settings-additions.json" <<'PYEOF'
import sys, json

settings_path = sys.argv[1]
additions_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

with open(additions_path) as f:
    additions = json.load(f)

if "hooks" not in settings:
    print("settings.json: no hooks section — nothing to remove")
    sys.exit(0)

removed = 0
for event, entries in additions.get("hooks", {}).items():
    if event not in settings["hooks"]:
        continue
    our_cmds = set()
    our_matchers = set()
    for entry in entries:
        for h in entry.get("hooks", []):
            our_cmds.add(h["command"])
        our_matchers.add(entry.get("matcher"))

    kept = []
    for existing in settings["hooks"][event]:
        existing_cmds = {h["command"] for h in existing.get("hooks", [])}
        if existing_cmds & our_cmds and existing.get("matcher") in our_matchers:
            removed += 1
        else:
            kept.append(existing)
    if kept:
        settings["hooks"][event] = kept
    else:
        del settings["hooks"][event]

# Drop the hooks key entirely if it ended up empty
if not settings.get("hooks"):
    settings.pop("hooks", None)

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"settings.json: {removed} hook entr{'y' if removed == 1 else 'ies'} removed")
PYEOF
fi

printf 'Done.\n'
printf '\n'
printf 'The claude-config repo itself is still at %s.\n' "$SCRIPT_DIR"
printf 'To delete it completely: rm -rf %s\n' "$SCRIPT_DIR"
