#!/usr/bin/env bash
# Fires on every message submission. Injects git context for /impl, /vuln, /upgrade commands.
# Exits immediately (near-zero overhead) if the message doesn't match.
# Always exits 0 — must never block Claude.

# Guard: if python3 is not available, skip silently
command -v python3 &>/dev/null || exit 0

# Read prompt from stdin JSON. Claude Code's UserPromptSubmit payload uses the
# key "prompt"; hookify's rule engine also accepts "user_prompt". Try all three
# known names for robustness across versions.
prompt=$(python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('prompt') or d.get('user_prompt') or d.get('message') or '')
except Exception:
    print('')
" 2>/dev/null) || true

if ! echo "$prompt" | grep -qE '^/(impl|vuln|upgrade)'; then
    exit 0
fi

echo "=== Auto-injected project context ==="
if git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Branch: $(git branch --show-current 2>/dev/null || echo 'unknown')"
    echo "Status:"
    git status --short 2>/dev/null | head -20
    echo "Recent commits:"
    git log --oneline -5 2>/dev/null
else
    echo "(not a git repository)"
fi
echo "Directory:"
ls -1 2>/dev/null | head -20

exit 0
