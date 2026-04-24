Implement the following: $ARGUMENTS

If the argument starts with `@`, treat it as a path to a markdown file. Resolve relative to the current working directory. Read its full content and use it as the description. Echo `📄 Reading prompt from \`<file>\`…` before proceeding. If the file cannot be read, stop and report the error immediately.

---

## Phase 0 — Load the description

If `@file` syntax: read the file, confirm `"Loaded prompt from <filename.md> (N lines)."`, note any embedded images as "referenced image: <path>". Otherwise use the inline text verbatim.

---

## Phase 1 — Clarification & Planning

**Rule: Ask, don't guess. This rule is absolute.**

Before producing a plan, analyze the description for:
- Ambiguous scope or unclear boundaries
- Missing constraints (performance, security, backwards-compatibility)
- Multiple valid implementation approaches
- Undefined integration points or dependencies
- Missing acceptance criteria

If **any** ambiguity exists, ask the user. Rules:
- Use `choices` arrays for every question — never plain text questions
- The **last choice** in every `choices` array MUST be `"Other… (describe)"` to allow free-text
- When a clearly superior default exists, make it the first choice and label it `"(Recommended)"`
- Group related decisions into a single question (minimize total questions)
- Do **not** proceed until all questions are answered

If **nothing** is ambiguous, skip directly to Phase 2.

---

## Phase 2 — Structured Plan

**Codebase exploration** — Before writing the plan, spawn an Explore subagent to map the relevant parts of the codebase:

→ Agent (subagent_type: "Explore"):
  "Given this implementation description: [SUBSTITUTE: the full implementation description from Phase 0 or Phase 1], find and return:
   - Relevant source files and their primary responsibility
   - Existing patterns and conventions used in this codebase
   - Test file locations and test naming conventions
   - Naming conventions (class names, method names, file names)
   Return a structured summary — no code changes."

**Wait for the agent's response before proceeding. Do not begin writing the plan until the file map is returned.**

→ Use the returned file map as codebase context when writing the plan below.

Produce a written implementation plan:

1. **Goal** — one-sentence summary of what will be built
2. **Approach** — chosen strategy and why
3. **Steps** — numbered, concrete implementation steps
4. **Files to create/modify** — list with brief rationale
5. **Tests** — what tests will be added or run
6. **Assumptions** — decisions made without user input (must be minimal)
7. **Out of scope** — explicitly list what is NOT being done

Then ask:
```
"Implementation plan ready. What would you like to do?"
choices: ["Approve & implement now (Recommended)", "Revise plan", "Cancel"]
```

- **Approve** → proceed to Phase 3 immediately
- **Revise** → ask what to change, update, re-show, re-ask
- **Cancel** → stop and summarize what was planned

---

## Phase 3 — Implementation

**Implement immediately. Do NOT ask "Should I implement?" or any variation.**

1. Work through each step in order
2. Make precise, surgical changes — do not modify unrelated code
3. Follow existing code style and LF line endings
4. Assume broad permissions; avoid unnecessary stops
5. If a **new ambiguity** emerges mid-implementation: STOP, ask with choices (last: `"Other… (describe)"`), resume after answer
6. After all changes: run relevant linters, builds, and tests; fix any failures caused by your changes
7. Verify the outcome matches the approved plan
8. **Post-implementation maintenance** — After verifying the outcome (step 7), first gather the actual change context that the three agents need:

   a. Run `git diff --stat` (or equivalent for uncommitted changes) and capture the list of changed files with line counts.
   b. Compose a **change summary block** in this format:
   ```
   Implementation: [one-sentence description of what was built]
   Files changed (from git diff --stat):
   <paste the git diff --stat output>
   Notable additions/removals: [new commands, APIs, config keys, dependencies — one line each; or "none"]
   ```

   Then spawn all three agents simultaneously in a single message, passing the full change summary block to each:

   **Agent 1 — Documentation** (general-purpose):
   > "Post-implementation documentation review. Change summary:
   > [paste change summary block]
   >
   > Scan for README.md, CHANGELOG.md, docs/, or any .md files in the project root or a docs/ directory.
   > Determine if documentation needs updating:
   > - Skip if: purely a bug fix, vulnerability fix, internal refactor, or test-only change
   > - Update if: new feature, changed behavior, new commands/APIs/config options, altered usage patterns
   > Use the file list above to reason precisely about what changed. If an update is warranted: apply minimal edits to the relevant section(s).
   > Return: file updated and what changed, OR 'no update required (reason)'."

   **Agent 2 — Knowledge base** (general-purpose):
   > "Post-implementation knowledge review. Change summary:
   > [paste change summary block]
   >
   > Check ~/.claude/memory/ (global) and .claude/memory/ (project-level, preferred for repo-specific knowledge) for existing knowledge files.
   > Determine if a new knowledge entry is warranted — look for: reusable insights or patterns, non-obvious constraints or gotchas, anti-patterns discovered, clarified trade-offs.
   > If YES: append to the most appropriate existing file (never create a new file if an existing one fits) using this format:
   > ### [Short title]
   > - **Context**: what problem/situation triggered this
   > - **Insight**: the learned rule, pattern, or gotcha
   > - **When it applies**: conditions under which this matters
   > - **Date**: YYYY-MM-DD
   > - **Ref**: [first 60 chars of implementation description]
   > Return: file updated/created and summary of entry, OR 'no update required'."

   **Agent 3 — Instructions** (general-purpose):
   > "Post-implementation instructions review. Change summary:
   > [paste change summary block]
   >
   > Check CLAUDE.md in the project root and ~/.claude/CLAUDE.md (global).
   > Determine if any rules, guidance, or guardrails are missing because of what this implementation revealed.
   > Skip if: the implementation followed existing patterns with no surprises, required no novel constraints, and introduced no anti-patterns. Only update if a concrete, recurring rule would have prevented a decision point or misunderstanding during this implementation.
   > If YES: apply minimal, additive, scoped changes only — do not rewrite sections wholesale.
   > Return: what was changed and why, OR 'no update required'."

   Collect the three summaries for the Phase 5 report. Then proceed to Phase 4.

---

## Phase 4 — Mandatory Knowledge & Instructions Maintenance

The documentation, knowledge, and instructions updates were handled by the three parallel agents spawned in Phase 3 step 8. Collect their summaries here to populate the Phase 5 report. Do not repeat the work.

If any agent reported an error or was skipped, note it in the Phase 5 report under the relevant section.

---

## Phase 5 — Final Report

Output a structured report — do NOT ask any closing confirmation:

```
## Implementation Report

### What was implemented
[High-level summary]

### Files changed
- path/to/file.ext — [what changed]

### Commands / tests run
- [command] → [result]

### Knowledge base
- [file updated/created] — [summary of entry] OR "no update required"

### Instructions
- [summary of change] OR "no update required"

### Documentation
- [file updated] — [what was added/changed] OR "no update required (bug fix / no user-facing change)" OR "no documentation files found"

### Assumptions & limitations
- [list any]
```

---

## Invariants (always enforced)

- NEVER make assumptions that could have been asked — ask instead
- NEVER end Phase 3 with "Should I implement?" — if approved, implement
- NEVER rewrite files wholesale when only an append/edit is needed
- NEVER skip Phase 3 step 8 — documentation, knowledge, and instructions maintenance is mandatory after every successful impl; always collect summaries for Phase 5
- ALWAYS spawn Phase 3 step 8 agents in a single message — never sequentially; then proceed to Phase 4
- NEVER skip Phase 4 — collect step 8 agent summaries even if all three returned "no update required"
- ALWAYS use `choices` arrays for decision points; last choice is always `"Other… (describe)"`
- ALWAYS produce the Phase 5 report as the final output
