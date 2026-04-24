Upgrade components: $ARGUMENTS

Each token is one of: `component:1.2.3` (exact), `component:minor` (latest patch on current minor), `component:latest` (latest stable), `component:lts` (latest LTS), or bare `component` (latest compatible with everything else).

`component` can be a library, framework, language runtime, build tool, or path like `.github/workflows`.

Reference files (read when needed):
- Ecosystem detection and update commands: `~/.claude/claude-config/references/upgrade/ecosystems.md`
- LTS lookup sources: `~/.claude/claude-config/references/upgrade/lts-sources.md`
- Compatibility constraints: `~/.claude/claude-config/references/upgrade/compatibility.md`
- Model routing: `~/.claude/claude-config/references/model-routing/classification.md`

All changes are left **uncommitted** on the current branch.

---

## Phase 1 — Compatibility Planning (no files changed)

1. **Inventory** — Detect all components and their current versions (build files, runtime version files, CI YAML). See `ecosystems.md`.

2. **Resolve** — For each token, determine the candidate target version. See "Version resolution" below.

3. **Research (parallel)** — Spawn two agents simultaneously:

   **Agent A** (general-purpose, needs WebFetch/WebSearch tools):
   > "For each component being upgraded: [list with current → target versions fetched in steps 1–2]. Fetch release notes and changelogs. Return per component:
   > - Known breaking changes
   > - Required companion upgrades (e.g. Spring Boot major → Hibernate, Mockito)
   > - Compatibility with other components in this upgrade set
   > - Any Java/Node/Python runtime version requirements"

   **Agent B** (general-purpose, needs Bash/Read/Edit tools) — **only spawn if `.github/workflows/` exists in the repository**:
   > "Scan all `.yml`/`.yaml` files in `.github/workflows/`. For each `uses: owner/action@ref`, fetch the latest release tag via: `gh api repos/<owner>/<action>/releases/latest --jq .tag_name`. Apply the updates in-place. Return: list of actions updated, any major version bumps flagged."

   After both agents complete, merge their reports into the upgrade plan before presenting it for user confirmation.

4. **Compatibility check** — Review the Agent A output for breaking changes and incompatibilities; if any, apply the conflict resolution logic below.

5. **Classify each component** — Apply `references/model-routing/classification.md` to each component in this upgrade set. Use the actual change required, not the component's popularity or size.

   | Condition on the upgrade | Classification |
   |---|---|
   | Same-major version bump, no documented breaking changes, no companion upgrades required | `MODERATE` |
   | GitHub Actions `uses:` bumps (Agent B's output) | `MODERATE` (en bloc) |
   | Major version bump, OR breaking changes flagged by Agent A, OR companion upgrades required, OR runtime (Java/Node/Python) upgrade, OR build-tool (Maven/Gradle/npm) upgrade | `SIGNIFICANT` / `HIGH-RISK` |
   | Any upgrade that touches security-sensitive code paths (auth, crypto, session, payment), migration logic, or framework-level components (Spring Boot, Rails, Next.js) | `HIGH-RISK` |

   If unsure, err toward `SIGNIFICANT`.

   Print a classification line per component:
   ```
   springboot 3.1.4 → 3.3.11: HIGH-RISK (framework major-minor bump, companion upgrades required)
   java 17 → 21: SIGNIFICANT (runtime major bump)
   commons-text 1.10.0 → 1.11.0: MODERATE (same-major, no breaking changes)
   ```

6. **Detect conflicts** — If any incompatibility is found, do NOT proceed. Instead:
   - Explain the conflict clearly (e.g. "Gradle 9 requires Java 17+, but the repo uses Java 11")
   - Offer concrete, ranked alternatives:
     - **Option A** — Lower the conflicting component to the highest compatible version
     - **Option B** — Upgrade the blocking dependency too (suggest version)
     - **Option C** — Skip this component
   - Ask the user to choose before continuing

7. **Confirm plan** — Before making any changes, print the upgrade plan (including per-component classification) and ask for confirmation if any version was auto-adjusted or companion upgrades were added.

8. **Opus planning for SIGNIFICANT / HIGH-RISK components** — After the user confirms the overall plan, for every component flagged `SIGNIFICANT` or `HIGH-RISK`, delegate its detailed plan to `workflow-tools:risk-planner`. The risk-planner has `Grep` / `Read` / `Glob` tools and is expected to do its own usage-site scan before producing the plan; the caller does not pre-compute that.

   → Agent (subagent_type: "workflow-tools:risk-planner"):
     > "Task description: Upgrade [component] from [current version] to [target version] in this repo.
     > Classification: [SIGNIFICANT | HIGH-RISK] — reason: [the criterion from step 5]
     > Codebase summary: inventory found the component in: [list of file paths from the Phase 1 step 1 inventory]. Release-notes and compat findings from Agent A: [paste Agent A's output for this component — breaking changes, companion upgrades, runtime requirements].
     > Constraints: [companion upgrades required; runtime version; any compatibility notes from Agent A]
     > Current state: branch = [git branch], uncommitted = [git status --short summary]
     >
     > Produce a risk-weighted plan per your skill. Before writing the plan, grep the repo for import sites and usage patterns of this component to understand the blast radius. Pay particular attention to: breaking API changes, migration order, test coverage of usage sites, rollback."

   **If the risk-planner returns a `### Re-classification` section** for any component (planner decided on inspection the upgrade is actually `MODERATE`), surface it and ask `choices: ["Accept revised classification (Recommended)", "Override and keep SIGNIFICANT/HIGH-RISK path", "Cancel component"]`. If accepted, drop that component to the MODERATE path for Phase 2 (standard apply → build → test with no Opus review gate). If overridden, re-invoke with the complete brief plus a note that the classification is intentional. Do not send a delta-only re-invocation.

   Otherwise, present each Opus plan to the user for approval before proceeding to that component.

### Version Resolution

| Token | Resolution |
|---|---|
| `component:1.2.3` | Use exact version; verify it exists; run compatibility check; surface conflicts (never silently downgrade) |
| `component:minor` | Latest stable patch within current `MAJOR.MINOR.*` |
| `component:latest` | Highest stable release; run compatibility check |
| `component:lts` | Consult official LTS source (see `lts-sources.md`); if lookup fails, ask the user |
| bare `component` | Highest version compatible with all other repo components; report conflict if none found |

---

## Phase 2 — Execution (after user confirms)

Process components **one at a time** in order:

1. **Baseline tests** (first component only) — Use the Agent tool with `subagent_type "workflow-tools:test-baseline"`. Pass the project root as context. Store the returned baseline; reuse for all subsequent component comparisons. Do not re-run the baseline for subsequent components — use the counts captured here for all comparisons throughout Phase 2.

2. **Detect** — Find the component. See `ecosystems.md`. If not found, warn and skip.

3. **Plan changes** — Identify all files that must change (build files, lock files, wrapper scripts, config, Docker base images, CI YAML — excluding `.github/workflows/` action refs already updated by Agent B in Phase 1).

4. **Apply** — Make the changes per `ecosystems.md` update commands.

5. **Companion upgrades** — Apply automatically and note in summary (e.g. Spring Boot major bump may require Hibernate, Mockito).

6. **Branch on classification:**

   **MODERATE components** → go to step 7 directly (build, then test).

   **SIGNIFICANT / HIGH-RISK components** → perform an Opus code review BEFORE building/testing:

   a. Capture the `git diff` for this component (and the companion-upgrade diffs applied in step 5).
   b. Spawn the reviewer:
      → Agent (subagent_type: "workflow-tools:code-review"):
        > "Task description: Upgrade [component] from [current] to [target] and any companion upgrades applied alongside it.
        > Classification: [SIGNIFICANT | HIGH-RISK]
        > Plan: [paste the Opus plan approved in Phase 1 step 8]
        > Diff: [paste git diff]
        > Project root: [absolute path]
        >
        > Produce an Opus code review per your skill. Focus on: migration order, breaking API changes, missed usage sites, dependency risk, rollback."
   c. Act on the return:
      - **`### Re-classification` section** — reviewer decided this component is actually `MODERATE`. Surface it, ask `choices: ["Accept revised classification (Recommended)", "Override and keep BLOCK-gated review", "Cancel component"]`. If accepted, drop this component to the MODERATE path — treat as implicit PASS, proceed to step 7, skip the re-review on later fix deltas. Record the revised classification for the summary table.
      - **BLOCK** — fix the blocking findings (current model or Sonnet), re-capture the diff, re-run the review. Do NOT proceed to step 7 until verdict is not BLOCK.
      - **PASS WITH RECOMMENDATIONS** — apply MAJOR findings in the same change before running tests; MINOR / NIT may be deferred.
      - **PASS** — proceed.

7. **Build** — Run the build command (no tests yet). If build fails, see "Handling build failures".

8. **Test** — Run full test suite.

9. **Compare** — Every previously-green test must still be green. If failures: see "Handling test failures". If fixes were applied and the component was STILL classified SIGNIFICANT / HIGH-RISK after step 6 (i.e. was NOT down-classified by the reviewer), re-invoke the Opus code review on the delta before re-running tests. If it was down-classified, skip the re-review.

After all components: print the summary table (Output section).

### Handling Test Failures

1. Inspect — determine if caused by breaking API change in the upgraded component
2. Auto-fix test code if straightforward (rename import, update assertion syntax, adjust config); explain every test change in the summary
3. If not auto-fixable, ask:
   > "These tests were passing before. Would you like me to: (1) Keep the upgrade and leave the failing tests for you to fix, (2) Revert this upgrade and skip it, (3) Investigate further?"

### Handling Build Failures

1. Read the full error output
2. Attempt auto-fix (wrong API, missing plugin version, incompatible config)
3. If unfixable: revert this component, warn the user, continue with the next

---

## Output

```
## Upgrade Summary

| Component  | Before | After  | Class       | Review | Status  | Notes                       |
|------------|--------|--------|-------------|--------|---------|-----------------------------|
| springboot | 3.1.4  | 3.3.11 | HIGH-RISK   | PASS   | OK      | Also upgraded hibernate 6.4 |
| java       | 17     | 21     | SIGNIFICANT | PASS W/RECS | OK | Updated 2 test files        |
| commons-text | 1.10 | 1.11   | MODERATE    | N/A    | OK      |                             |
| redis      | -      | -      | -           | -      | SKIPPED | Not found in project        |

Tests: 142 passed, 0 regressions (baseline: 142 passing)
```

---

## Invariants (always enforced)

- NEVER skip per-component classification in Phase 1 step 5
- NEVER use Opus for a MODERATE component upgrade unless the user explicitly requests it
- NEVER run tests on a SIGNIFICANT / HIGH-RISK component before the Opus code review returns a non-BLOCK verdict
- ALWAYS include the classification column in the final summary table
- ALWAYS compare against the Baseline agent's results captured once at the start of Phase 2
