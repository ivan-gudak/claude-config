#!/usr/bin/env bash
# Idempotent installer — safe to re-run after every git pull.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

printf 'Installing claude-config from %s\n' "$SCRIPT_DIR"

# ── Ensure target directories exist ──────────────────────────────────────────

mkdir -p "$CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/hooks"
mkdir -p "$CLAUDE_DIR/plugins"

# ── Command symlinks ──────────────────────────────────────────────────────────
# ln -sf replaces existing regular files or symlinks with a fresh symlink.

for cmd in impl.md vuln.md upgrade.md; do
    ln -sf "../claude-config/commands/$cmd" "$CLAUDE_DIR/commands/$cmd"
    printf '  linked commands/%s\n' "$cmd"
done

# ── Plugin directory symlink ──────────────────────────────────────────────────
# If a real (non-symlink) directory exists at the target, remove it first so
# ln -sf can create a symlink in its place.

plugin_target="$CLAUDE_DIR/plugins/workflow-tools"
if [[ -d "$plugin_target" && ! -L "$plugin_target" ]]; then
    rm -rf "$plugin_target"
fi
ln -sf "../claude-config/plugins/workflow-tools" "$plugin_target"
printf '  linked plugins/workflow-tools\n'

# ── Hook script symlinks ──────────────────────────────────────────────────────

for hook in notify-done.sh preload-context.sh test-notify.sh; do
    ln -sf "../claude-config/hooks/$hook" "$CLAUDE_DIR/hooks/$hook"
    printf '  linked hooks/%s\n' "$hook"
done

# ── Merge hook entries into settings.json ────────────────────────────────────

if [[ ! -f "$CLAUDE_DIR/settings.json" ]]; then
    printf '  settings.json not found — creating empty skeleton\n'
    printf '{}' > "$CLAUDE_DIR/settings.json"
fi

python3 - "$CLAUDE_DIR/settings.json" "$SCRIPT_DIR/settings-additions.json" <<'PYEOF'
import sys, json, os

settings_path = sys.argv[1]
additions_path = sys.argv[2]

with open(settings_path) as f:
    settings = json.load(f)

with open(additions_path) as f:
    additions = json.load(f)

if "hooks" not in settings:
    settings["hooks"] = {}

added = 0
for event, entries in additions.get("hooks", {}).items():
    if event not in settings["hooks"]:
        settings["hooks"][event] = []
    for new_entry in entries:
        new_cmds = frozenset(h["command"] for h in new_entry.get("hooks", []))
        new_matcher = new_entry.get("matcher")
        already_exists = any(
            frozenset(h["command"] for h in ex.get("hooks", [])) == new_cmds
            and ex.get("matcher") == new_matcher
            for ex in settings["hooks"][event]
        )
        if not already_exists:
            settings["hooks"][event].append(new_entry)
            added += 1

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(f"settings.json: {added} hook entr{'y' if added == 1 else 'ies'} added")
PYEOF

printf 'Done.\n'
