Upgrade components: $ARGUMENTS

Each token is one of: `component:1.2.3` (exact), `component:minor` (latest patch on current minor), `component:latest` (latest stable), `component:lts` (latest LTS), or bare `component` (latest compatible with everything else).

`component` can be a library, framework, language runtime, build tool, or path like `.github/workflows`.

Reference files (read when needed):
- Ecosystem detection and update commands: `~/.copilot/skills/upgrade/references/ecosystems.md`
- LTS lookup sources: `~/.copilot/skills/upgrade/references/lts-sources.md`
- Compatibility constraints: `~/.copilot/skills/upgrade/references/compatibility.md`

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

5. **Detect conflicts** — If any incompatibility is found, do NOT proceed. Instead:
   - Explain the conflict clearly (e.g. "Gradle 9 requires Java 17+, but the repo uses Java 11")
   - Offer concrete, ranked alternatives:
     - **Option A** — Lower the conflicting component to the highest compatible version
     - **Option B** — Upgrade the blocking dependency too (suggest version)
     - **Option C** — Skip this component
   - Ask the user to choose before continuing

6. **Confirm plan** — Before making any changes, print the upgrade plan and ask for confirmation if any version was auto-adjusted or companion upgrades were added.

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

1. **Baseline tests** (first component only) — Use the Agent tool with `subagent_type "workflow-tools:test-baseline"`. Pass the project root as context. Store the returned baseline; reuse for all subsequent component comparisons.
2. **Detect** — Find the component. See `ecosystems.md`. If not found, warn and skip.
3. **Plan changes** — Identify all files that must change (build files, lock files, wrapper scripts, config, Docker base images, CI YAML).
4. **Apply** — Make the changes per `ecosystems.md` update commands.
5. **Companion upgrades** — Apply automatically and note in summary (e.g. Spring Boot major bump may require Hibernate, Mockito).
6. **Build** — Run the build command (no tests yet). If build fails, see "Handling build failures".
7. **Test** — Run full test suite again.
8. **Compare** — Every previously-green test must still be green. If failures: see "Handling test failures".
9. After all components: print summary table.

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

| Component  | Before | After  | Status  | Notes                       |
|------------|--------|--------|---------|-----------------------------|
| springboot | 3.1.4  | 3.3.11 | OK      | Also upgraded hibernate 6.4 |
| java       | 17     | 21     | OK      | Updated 2 test files        |
| redis      | -      | -      | SKIPPED | Not found in project        |

Tests: 142 passed, 0 regressions (baseline: 142 passing)
```
