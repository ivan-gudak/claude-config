Fix security vulnerabilities: $ARGUMENTS

Each argument token is either `JIRA-ID:CVE-ID` (e.g. `MGD-2423:CVE-2023-46604`) or a bare `CVE-ID` (e.g. `CVE-2023-46604`). Parse and filter each token (steps 1–2), then research all CVEs in parallel (step 3) before applying fixes sequentially (steps 7–10).

Reference files (read when needed):
- Build system detection: `~/.copilot/skills/fix-vuln/references/build-systems.md`
- NVD API usage: `~/.copilot/skills/fix-vuln/references/nvd-api.md`

---

## Workflow

For each vulnerability token:

1. **Parse** — Extract JIRA-ID (optional) and CVE-ID.
   - `JIRA-ID:CVE-ID` format when the part before `:` matches `[A-Z]+-\d+`
   - Bare CVE-ID otherwise
   - Determine NOJIRA placeholder once: scan `git log --oneline -50` and `git branch -a` for patterns like `NOJIRA`. Use it in branch names where applicable; omit entirely if history is ambiguous.

2. **Filter** — Skip non-CVE IDs (CWE-*, OWASP `\d{4}:A\d`). Warn and continue.

3. **Research (parallel)** — Before applying any fix, spawn all of the following agents simultaneously in a single message:

   **For each CVE-ID remaining after filtering:**

   - **NVD agent** (general-purpose, needs WebFetch/WebSearch):
     > "Fetch CVE details for [CVE-ID] using the NVD API. Reference: `~/.copilot/skills/fix-vuln/references/nvd-api.md`.
     > Return: affected package name, vulnerable version range, minimum safe version, one-line CVE description."

   - **Detect agent** (Explore):
     > "Scan this repository for the dependency [package name from the CVE]. Check: pom.xml, build.gradle, build.gradle.kts, package.json, requirements.txt, go.mod, Cargo.toml. Reference: `~/.copilot/skills/fix-vuln/references/build-systems.md`.
     > Return: current version in use, file paths where the dependency appears."

   **Once per batch (not per CVE):**

   - **Baseline agent** (workflow-tools:test-baseline):
     > Run the full test suite and return structured baseline results.

   Wait for all agents to complete before proceeding. If the NVD agent cannot determine the package name, use the CVE ID to make a reasonable inference for the Detect agent.

4. **Merge research results** — Combine the parallel agent outputs: CVE details, current library version, safe target version. For each CVE, confirm a fix is needed (current version falls within the vulnerable range). Skip with a warning if the library is not found in the repo.

5. **Version** — Safe target version is the minimum safe version returned by the NVD agent. If ambiguous, use the lowest fixed version in the CVE's affected range.

6. **Baseline** — Already captured by the Baseline agent in step 3. Do not re-run the test suite.

7. **Fix** — Apply the minimal version change. Prefer patch/minor bump; avoid major version changes unless unavoidable.

8. **Verify** — Build the project and re-run tests.

9. **Compare** — Diff before/after test results:
   - All previously-green tests must stay green
   - If previously-green tests fail: present them clearly and ask the user to choose — proceed anyway, revert, or investigate further

10. **Commit & PR** — Commit to a new branch and open a PR.

---

## Git Workflow

**Branch naming** (match project convention from `git log --oneline -50`):

- With Jira ID: `fix/JIRA-ID-CVE-XXXX-XXXXX`
- Without Jira ID: `fix/NOJIRA-CVE-XXXX-XXXXX` (or `fix/CVE-XXXX-XXXXX` if project omits placeholders)

**Commit message** (match project style):

```
fix(deps): upgrade <library> to <version> to remediate <CVE-ID>

[Resolves <JIRA-ID>]
Fixes <CVE-ID> - <one-line CVE description>

Vulnerable range: <range>
Safe version: <version>

Co-authored-by: Claude Code <noreply@anthropic.com>
```

Omit the `Resolves` line when there is no Jira ID.

**PR:**
- Base branch: `main` (fallback: `master`)
- Title: `fix(deps): <library> upgrade to remediate <CVE-ID>` (append ` [<JIRA-ID>]` when present)
- Body: CVE summary, vulnerable range, version change made, test results (pass count before vs. after)

---

## Handling Test Failures After Fix

If the fix causes previously-green tests to fail and a quick investigation reveals no obvious fix:

Present the failing tests and ask:
```
"These tests were passing before. Would you like me to:
(1) Apply the fix anyway and flag the failures in the PR description
(2) Revert the fix
(3) Investigate further"
```

Honor the user's choice.
