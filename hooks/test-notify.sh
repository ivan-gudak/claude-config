#!/usr/bin/env bash
# Fires after every Bash tool call. Detects test suite commands, parses results, notifies.
# Always exits 0 — must never block Claude.

# Guard: if python3 is not available, skip silently
command -v python3 &>/dev/null || exit 0

input=$(cat)

command=$(echo "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('command', ''))
except Exception:
    print('')
" 2>/dev/null) || true

output=$(echo "$input" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('output', ''))
except Exception:
    print('')
" 2>/dev/null) || true

# Exit early if this wasn't a test command
if ! echo "$command" | grep -qE '(mvn test|gradlew test|gradle test|npm test|yarn test|pytest|make test)'; then
    exit 0
fi

# Parse result using python3 (portable — no grep -P)
summary=$(python3 - "$command" "$output" 2>/dev/null <<'PYEOF'
import sys, re

cmd = sys.argv[1] if len(sys.argv) > 1 else ""
out = sys.argv[2] if len(sys.argv) > 2 else ""

def first(pattern, text, default="0"):
    m = re.findall(pattern, text)
    return m[-1] if m else default

def sumall(pattern, text, default="0"):
    vals = [int(x) for x in re.findall(pattern, text) if x.isdigit()]
    return str(sum(vals)) if vals else default

if "mvn" in cmd:
    total = sumall(r"Tests run: (\d+)", out)
    failures = sumall(r"Failures: (\d+)", out)
    errors = sumall(r"Errors: (\d+)", out)
    print(f"{total} run, {failures} failed, {errors} errors")
elif "gradlew" in cmd or "gradle" in cmd:
    total = first(r"(\d+) tests? completed", out)
    failed = first(r", (\d+) failed", out)
    print(f"{total} completed, {failed} failed")
elif "pytest" in cmd:
    passed = first(r"(\d+) passed", out)
    failed = first(r"(\d+) failed", out)
    print(f"{passed} passed, {failed} failed")
elif "npm" in cmd or "yarn" in cmd:
    passed = first(r"Tests:.*?(\d+) passed", out)
    failed = first(r"Tests:.*?(\d+) failed", out)
    print(f"{passed} passed, {failed} failed")
else:
    print("tests completed")
PYEOF
) || true

[[ -z "$summary" ]] && summary="tests completed"
message="Test run: $summary"

# Notify using platform-appropriate method
if [[ "$OSTYPE" == "darwin"* ]]; then
    osascript -e "display notification \"$message\" with title \"Claude Code\"" 2>/dev/null || true
elif grep -qi microsoft /proc/version 2>/dev/null; then
    wsl-notify-send --category "Claude Code" "$message" 2>/dev/null || \
    powershell.exe -Command \
      "[System.Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms') | Out-Null; \$n = New-Object System.Windows.Forms.NotifyIcon; \$n.Icon = [System.Drawing.SystemIcons]::Information; \$n.Visible = \$true; \$n.ShowBalloonTip(3000, 'Claude Code', '$message', [System.Windows.Forms.ToolTipIcon]::None); Start-Sleep -Milliseconds 3500; \$n.Dispose()" 2>/dev/null || \
    echo -e '\a'
else
    notify-send "Claude Code" "$message" 2>/dev/null || echo -e '\a'
fi

exit 0
