#!/usr/bin/env bash
# Fires on every message submission. Injects git context for /impl, /vuln, /upgrade commands.
# Exits immediately (near-zero overhead) if the message doesn't match.
# Always exits 0 — must never block Claude.
set -euo pipefail

# Read message from stdin JSON
message=$(python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    print(data.get('message', ''))
except Exception:
    print('')
" 2>/dev/null)

if ! echo "$message" | grep -qE '^/(impl|vuln|upgrade)'; then
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
