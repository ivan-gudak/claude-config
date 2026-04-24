---
name: test-baseline
description: Run the full test suite and return structured results for regression comparison. Use before making changes to capture a baseline. Inherits the main session's model — does not require Opus.
tools: ["Bash", "Read", "Glob", "LS"]
---

Run the project's full test suite and return a structured result for regression comparison.

## Steps

1. **Detect framework** — Search the working directory for build/config files in this order:
   - `pom.xml` → Maven, command: `mvn test -q`
   - `build.gradle` or `build.gradle.kts` → Gradle, command: `./gradlew test` (fall back to `gradle test` if no wrapper)
   - `package.json` → read the `scripts.test` field; if absent, use `npm test`
   - `pyproject.toml`, `setup.py`, or `pytest.ini` → pytest, command: `pytest -v`
   - `Makefile` containing a `test` target → `make test`
   - If no framework found: return the structure below with Framework = "not detected", all counts = 0, and a note explaining no runner was found. Do not fail.

2. **Run** — Execute the detected command. Allow up to 10 minutes. Capture stdout and stderr combined.

3. **Parse** — Extract from the output:

   | Framework | Passing count pattern | Failing count pattern |
   |-----------|----------------------|-----------------------|
   | Maven | `Tests run: X` minus failures+errors | `Failures: Y, Errors: Z` |
   | Gradle | `X tests completed` minus failed | `, Y failed` |
   | pytest | `X passed` | `Y failed` or `Y error` |
   | Jest/npm | `X passed` | `Y failed` |

   Also collect the names/identifiers of every passing test and every failing test from the verbose output.

4. **Return this exact structure and nothing else:**

```markdown
## Test Baseline
- **Framework**: [name or "not detected"]
- **Command**: `[command used]`
- **Total**: [n] | **Passing**: [n] | **Failing**: [n] | **Skipped**: [n]

### Pre-existing failures
[one test identifier per line — or "none"]

### Passing tests
[one test identifier per line]
```
