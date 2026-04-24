#!/usr/bin/env bash
# Idempotent installer — safe to re-run after every git pull.
#
# Flags:
#   --no-hooks    Skip hook script symlinks and settings.json merge
#   --help        Show this help
set -euo pipefail

install_hooks=1

for arg in "$@"; do
    case "$arg" in
        --no-hooks)  install_hooks=0 ;;
        --help|-h)
            cat <<'EOF'
Usage: bash install.sh [OPTIONS]

Options:
  --no-hooks    Install commands and agents only. If hooks were previously installed,
                they will be ACTIVELY REMOVED (symlinks unlinked, settings.json entries stripped).
                Use this if you don't want notifications or auto-injected git context.
  -h, --help    Show this help.

Without flags, installs everything. Re-running with different flags converges to the
requested state — safe and idempotent either way.

Note: The three subagents (test-baseline, risk-planner, code-review) are required
by /vuln and /upgrade and by the Opus-gated planning / review flow in /impl. There
is no flag to opt out — the commands will not function without them.
EOF
            exit 0
            ;;
        *)
            printf 'ERROR: unknown argument: %s\n' "$arg" >&2
            printf 'Run "bash install.sh --help" for usage.\n' >&2
            exit 1
            ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
EXPECTED_CLAUDE_DIR="$HOME/.claude"

if [[ "$CLAUDE_DIR" != "$EXPECTED_CLAUDE_DIR" ]]; then
    printf 'ERROR: install.sh must run from within %s/claude-config/\n' "$EXPECTED_CLAUDE_DIR" >&2
    printf '  Detected script location: %s\n' "$SCRIPT_DIR" >&2
    printf '  Detected parent:          %s (expected: %s)\n' "$CLAUDE_DIR" "$EXPECTED_CLAUDE_DIR" >&2
    printf '\n' >&2
    printf 'Expected setup:\n' >&2
    printf '  cd ~/.claude && git clone <repo-url> claude-config\n' >&2
    printf '  cd claude-config && bash install.sh\n' >&2
    exit 1
fi

printf 'Installing claude-config from %s\n' "$SCRIPT_DIR"
[[ $install_hooks -eq 0 ]] && printf '  (hooks skipped — --no-hooks)\n'

# ── Ensure target directories exist ──────────────────────────────────────────

mkdir -p "$CLAUDE_DIR/commands"
mkdir -p "$CLAUDE_DIR/agents"
[[ $install_hooks -eq 1 ]] && mkdir -p "$CLAUDE_DIR/hooks"

# ── Helper: remove a path only if it's our symlink (points into claude-config/).
#    Safe for paths that don't exist.
remove_our_symlink() {
    local link="$1"
    if [[ -L "$link" ]]; then
        local target
        target=$(readlink "$link")
        if [[ "$target" == *"/claude-config/"* || "$target" == "../claude-config/"* ]]; then
            rm -rf "$link"
            printf '  removed %s (was managed)\n' "$link"
        fi
    fi
}

# ── Command symlinks ──────────────────────────────────────────────────────────
# ln -sf replaces existing regular files or symlinks with a fresh symlink.

for cmd in impl.md vuln.md upgrade.md; do
    ln -sf "../claude-config/commands/$cmd" "$CLAUDE_DIR/commands/$cmd"
    printf '  linked commands/%s\n' "$cmd"
done

# ── Agent symlinks (user-level subagents) ─────────────────────────────────────
# Each agent file at ~/.claude/agents/<name>.md is auto-discovered by Claude Code
# via its YAML frontmatter and callable as Agent(subagent_type: "<name>").
# Replaces the earlier plugin-based approach, which required marketplace
# registration Claude Code's local-dir discovery does not support.

for agent in test-baseline.md risk-planner.md code-review.md; do
    ln -sf "../claude-config/agents/$agent" "$CLAUDE_DIR/agents/$agent"
    printf '  linked agents/%s\n' "$agent"
done

# Cleanup: if the legacy plugins/workflow-tools/ symlink is still around from
# a pre-restructure install, remove it. Otherwise ~/.claude/plugins/ will be
# a dead directory with a broken symlink.
legacy_plugin_target="$CLAUDE_DIR/plugins/workflow-tools"
remove_our_symlink "$legacy_plugin_target"
# Drop the parent plugins/ dir if it's empty after cleanup.
if [[ -d "$CLAUDE_DIR/plugins" ]] && [[ -z "$(ls -A "$CLAUDE_DIR/plugins" 2>/dev/null)" ]]; then
    rmdir "$CLAUDE_DIR/plugins" 2>/dev/null || true
fi

# ── Hook script symlinks ──────────────────────────────────────────────────────

if [[ $install_hooks -eq 1 ]]; then
    for hook in notify-done.sh preload-context.sh test-notify.sh; do
        ln -sf "../claude-config/hooks/$hook" "$CLAUDE_DIR/hooks/$hook"
        printf '  linked hooks/%s\n' "$hook"
    done
else
    # --no-hooks: actively uninstall our managed hook symlinks if present.
    for hook in notify-done.sh preload-context.sh test-notify.sh; do
        remove_our_symlink "$CLAUDE_DIR/hooks/$hook"
    done
fi

# ── Merge / strip hook entries in settings.json ──────────────────────────────

if [[ ! -f "$CLAUDE_DIR/settings.json" ]]; then
    if [[ $install_hooks -eq 1 ]]; then
        printf '  settings.json not found — creating empty skeleton\n'
        printf '{}' > "$CLAUDE_DIR/settings.json"
    fi
fi

if [[ -f "$CLAUDE_DIR/settings.json" ]]; then
    python3 - "$CLAUDE_DIR/settings.json" "$SCRIPT_DIR/settings-additions.json" "$install_hooks" <<'PYEOF'
import sys, json

settings_path = sys.argv[1]
additions_path = sys.argv[2]
install_hooks = sys.argv[3] == "1"

with open(settings_path) as f:
    settings = json.load(f)

with open(additions_path) as f:
    additions = json.load(f)

if install_hooks:
    # Merge: add any of our entries that aren't already present.
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
    msg = f"settings.json: {added} hook entr{'y' if added == 1 else 'ies'} added"
else:
    # --no-hooks: strip our entries from settings.json if present.
    removed = 0
    if "hooks" in settings:
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
        if not settings.get("hooks"):
            settings.pop("hooks", None)
    msg = f"settings.json: {removed} hook entr{'y' if removed == 1 else 'ies'} removed"

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
    f.write("\n")

print(msg)
PYEOF
fi

printf 'Done.\n'
