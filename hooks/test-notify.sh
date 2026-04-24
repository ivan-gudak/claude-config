#!/usr/bin/env bash
# Fires after every Bash tool call. Detects test suite commands, parses results, notifies.
# Always exits 0 — must never block Claude.
set -euo pipefail

input=$(cat)

command=$(python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('command', ''))
except Exception:
    print('')
" 2>/dev/null <<< "$input")

output=$(python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('output', ''))
except Exception:
    print('')
" 2>/dev/null <<< "$input")

# Exit early if this wasn't a test command
if ! echo "$command" | grep -qE '(mvn test|gradlew test|gradle test|npm test|yarn test|pytest|make test)'; then
    exit 0
fi

# Parse result by framework
summary=""

# Maven: "Tests run: X, Failures: Y, Errors: Z"
if echo "$command" | grep -q "mvn"; then
    total=$(echo "$output" | grep -oP 'Tests run: \K[0-9]+' | awk '{s+=$1} END {print s}')
    failures=$(echo "$output" | grep -oP 'Failures: \K[0-9]+' | awk '{s+=$1} END {print s}')
    errors=$(echo "$output" | grep -oP 'Errors: \K[0-9]+' | awk '{s+=$1} END {print s}')
    [[ -n "$total" ]] && summary="${total} run, ${failures:-0} failed, ${errors:-0} errors"

# Gradle: "X tests completed, Y failed"
elif echo "$command" | grep -qE "gradlew|gradle"; then
    total=$(echo "$output" | grep -oP '[0-9]+ tests? completed' | grep -oP '[0-9]+' | tail -1)
    failed=$(echo "$output" | grep -oP ', [0-9]+ failed' | grep -oP '[0-9]+' | tail -1)
    [[ -n "$total" ]] && summary="${total} completed, ${failed:-0} failed"

# pytest: "X passed, Y failed"
elif echo "$command" | grep -q "pytest"; then
    passed=$(echo "$output" | grep -oP '[0-9]+ passed' | grep -oP '[0-9]+' | tail -1)
    failed=$(echo "$output" | grep -oP '[0-9]+ failed' | grep -oP '[0-9]+' | tail -1)
    [[ -n "$passed" ]] && summary="${passed} passed, ${failed:-0} failed"

# Jest/npm: "Tests: X passed, Y failed, Z total"
elif echo "$command" | grep -qE "npm|yarn"; then
    passed=$(echo "$output" | grep -oP 'Tests:.*?([0-9]+) passed' | grep -oP '[0-9]+' | tail -1)
    failed=$(echo "$output" | grep -oP 'Tests:.*?([0-9]+) failed' | grep -oP '[0-9]+' | tail -1)
    [[ -n "$passed" ]] && summary="${passed} passed, ${failed:-0} failed"
fi

[[ -z "$summary" ]] && summary="tests completed"
message="Test run: $summary"

# Notify using platform-appropriate method
if [[ "$OSTYPE" == "darwin"* ]]; then
    osascript -e "display notification \"$message\" with title \"Claude Code\"" 2>/dev/null || true
elif grep -qi microsoft /proc/version 2>/dev/null; then
    wsl-notify-send --category "Claude Code" "$message" 2>/dev/null || echo -e '\a'
else
    notify-send "Claude Code" "$message" 2>/dev/null || echo -e '\a'
fi

exit 0
