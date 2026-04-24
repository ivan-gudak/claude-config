Fix security vulnerabilities: $ARGUMENTS

Each argument token is either `JIRA-ID:CVE-ID` (e.g. `MGD-2423:CVE-2023-46604`) or a bare `CVE-ID` (e.g. `CVE-2023-46604`). Parse and filter each token (steps 1–2), then research all CVEs in parallel (step 3) before applying fixes sequentially (steps 5 onward).

Reference files (read when needed):
- Build system detection: `~/.claude/claude-config/references/fix-vuln/build-systems.md`
- NVD API usage: `~/.claude/claude-config/references/fix-vuln/nvd-api.md`
- Model routing: `~/.claude/claude-config/references/model-routing/classification.md`

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
     > "Fetch CVE details for [CVE-ID] using the NVD API. Reference: `~/.claude/claude-config/references/fix-vuln/nvd-api.md`.
     > Return: affected package name, vulnerable version range, minimum safe version, one-line CVE description."

   - **Detect agent** (Explore):
     > "Scan this repository for the dependency [package name from the CVE]. Check: pom.xml, build.gradle, build.gradle.kts, package.json, requirements.txt, go.mod, Cargo.toml. Reference: `~/.claude/claude-config/references/fix-vuln/build-systems.md`.
     > Return: current version in use, file paths where the dependency appears."

   **Once per batch (not per CVE):**

   - **Baseline agent** (workflow-tools:test-baseline):
     > Run the full test suite and return structured baseline results.

   Wait for all agents to complete before proceeding. If the NVD agent cannot determine the package name, use the CVE ID to make a reasonable inference for the Detect agent.

4. **Merge research results** — Combine the parallel agent outputs: CVE details, current library version, safe target version. For each CVE, confirm a fix is needed (current version falls within the vulnerable range). Skip with a warning if the library is not found in the repo.

5. **Classify each CVE fix** — For every CVE that requires a fix, apply the routing rules from `references/model-routing/classification.md`. Decide based on the ACTUAL change required, not the CVE's CVSS score.

   | Condition on the fix | Classification |
   |---|---|
   | Same-major version bump (e.g. `2.14.1 → 2.14.3`, `2.14.x → 2.15.0`), library used as a drop-in, no consumer-code change expected | `MODERATE` |
   | Major version bump (e.g. `2.x → 3.x`), OR the new version has documented API changes that will require code edits, OR the library is used in security-sensitive code paths (auth, crypto, session, payment) | `SIGNIFICANT` / `HIGH-RISK` |

   If unsure, err toward `SIGNIFICANT`. Print the classification and the reason before touching files.

6. **Version** — Safe target version is the minimum safe version returned by the NVD agent. If ambiguous, use the lowest fixed version in the CVE's affected range.

7. **Baseline** — Already captured by the Baseline agent in step 3. Do not re-run the test suite.

---

## Sequential fix — MODERATE path

For CVEs classified `MODERATE`, fix one at a time:

1. **Fix** — Apply the minimal version change (patch/minor).
2. **Verify** — Build the project. (Tests come after — see step 4 below.)
3. **Run tests** — Re-run the test suite.
4. **Compare** — Diff before/after test results:
   - All previously-green tests must stay green
   - If previously-green tests fail: present them clearly and ask the user to choose — proceed anyway, revert, or investigate further
5. **Commit & PR** — See the Git Workflow section.

---

## Sequential fix — SIGNIFICANT / HIGH-RISK path

For CVEs classified `SIGNIFICANT` or `HIGH-RISK`, fix one at a time:

1. **Plan with Opus** — Delegate planning to `workflow-tools:risk-planner`. The risk-planner has `Grep` / `Read` / `Glob` tools and will do its own usage-site scan; the Detect agent only returned declaration paths, not import sites.

   → Agent (subagent_type: "workflow-tools:risk-planner"):
     > "Task description: Remediate [CVE-ID] in [repo name]. Upgrade [library] from [current version] to [target version]. [One-line CVE description.]
     > Classification: [SIGNIFICANT | HIGH-RISK] — reason: [from step 5]
     > Codebase summary: Detect agent found the dependency declared in: [list of declaration file paths from step 3]. Current version: [current]. Target version: [target].
     > Constraints: keep breaking changes out of consumer code if avoidable; if unavoidable, enumerate them.
     > Current state: branch = [git branch], uncommitted = [git status --short summary]
     >
     > Produce a risk-weighted plan per your skill. Before writing the plan, grep the repo for import sites and usage patterns of this library to understand the blast radius of a version bump / API change."

   **If the risk-planner returns a `### Re-classification` section** instead of a full plan (it decided the CVE fix is actually `MODERATE` on inspection — e.g. a drop-in patch bump with no consumer-code change), surface it and ask `choices: ["Accept revised classification (Recommended)", "Override and keep HIGH-RISK path", "Cancel"]`. If accepted, fall back to the MODERATE path for this CVE. If overridden, re-invoke with the complete brief plus a note that the classification is intentional. Do not send a delta-only re-invocation.

   Otherwise, present the plan to the user and ask for approval before touching files.

2. **Apply the fix** — With current model or Sonnet. Version bump + any code changes per the plan. No tests yet.

3. **Opus code review** — Capture the full `git diff` for this CVE fix, then:

   → Agent (subagent_type: "workflow-tools:code-review"):
     > "Task description: Remediate [CVE-ID] — upgrade [library] from [current] to [target].
     > Classification: [SIGNIFICANT | HIGH-RISK]
     > Plan: [paste risk-planner plan]
     > Diff: [paste git diff]
     > Project root: [absolute path]
     >
     > Produce an Opus code review per your skill. Focus especially on security, dependency risk, migration (library API changes), and rollback."

4. **Act on the return:**
   - **`### Re-classification` section** — the reviewer decided the change is actually `MODERATE`. Surface it and ask `choices: ["Accept revised classification (Recommended)", "Override and keep BLOCK-gated review", "Cancel"]`. If accepted, treat as an implicit PASS and proceed to step 5; do NOT re-invoke code-review on fix deltas. Record the revised classification for the PR body.
   - **BLOCK** — fix the blocking findings (current model or Sonnet), re-capture the diff, re-run the review. Do not run tests until the verdict is not BLOCK.
   - **PASS WITH RECOMMENDATIONS** — apply MAJOR findings before running tests. MINOR / NIT may be deferred; note them in the PR description.
   - **PASS** — proceed.

5. **Build & run tests** — Build the project; re-run the test suite.

6. **Compare** — Diff before/after against the baseline:
   - All previously-green tests must stay green
   - If previously-green tests fail: present them clearly and ask the user to choose — proceed anyway, revert, or investigate further
   - If fixes were applied in response to failures, re-run tests; if the fixes were non-trivial AND the reviewer was NOT down-classified in step 4, re-invoke the Opus review on the delta. If it was down-classified, skip the re-review.

7. **Commit & PR** — See the Git Workflow section. Include the review verdict in the PR body.

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
Classification: <MODERATE | SIGNIFICANT | HIGH-RISK>

Co-authored-by: Claude Code <noreply@anthropic.com>
```

Omit the `Resolves` line when there is no Jira ID.

**PR:**
- Base branch: `main` (fallback: `master`)
- Title: `fix(deps): <library> upgrade to remediate <CVE-ID>` (append ` [<JIRA-ID>]` when present)
- Body: CVE summary, vulnerable range, version change made, classification, test results (pass count before vs. after). For SIGNIFICANT / HIGH-RISK: paste the Opus review verdict and any deferred MINOR / NIT findings.

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

---

## Invariants (always enforced)

- NEVER skip classification (step 5) — every CVE fix must be labelled
- NEVER use Opus for a MODERATE fix unless the user explicitly requests it
- NEVER run the test suite on a SIGNIFICANT / HIGH-RISK fix before the Opus code review returns a non-BLOCK verdict
- ALWAYS include the classification in the commit message and PR body
- ALWAYS compare against the Baseline agent's results — a regression is only real vs. the pre-change baseline
