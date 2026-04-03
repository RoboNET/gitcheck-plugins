---
name: spec
description: Universal pipeline-driven skill for all spec operations. Handles status, validation, creation, navigation, linking, and pipeline advancement. Reads pipeline.yaml for configuration.
user_invocable: true
---

# Universal Spec Skill

Single entry point for all specification pipeline operations. This skill is **pipeline-agnostic** -- it reads `specs/pipeline.yaml` to discover document types, flows, templates, and instructions. No step names, document types, or ID prefixes are hardcoded.

## Subcommands

```
/spec                     Show this help
/spec status [ID]         Show pipeline status for all root documents or a specific one
/spec validate            Run integrity checks on all spec documents
/spec next [ID]           Determine and execute the next pipeline step
/spec graph ID            Show dependency tree for a document
/spec linked ID [--depth N]  Show impact radius for a document
/spec list [type]         List all documents, optionally filtered by type
/spec new <type> [title]  Create a new document of any pipeline-defined type
/spec link <FROM> <TYPE> <TO>  Add a link between two documents
/spec link --remove <FROM> <TYPE> <TO>  Remove a link
/spec link --list ID      Show all links for a document
/spec cascade [ID]        Check upstream documents for staleness
/spec inbox               Check open spec PRs for unresolved review comments
/spec recompute           Recompute reverse_links across all documents
```

If invoked as `/spec` with no arguments, display the subcommand list above and a one-line summary of pipeline health (e.g., "3 features tracked, 2 have pending steps").

---

## Initialization (every invocation)

1. **Read pipeline config**: `specs/pipeline.yaml` -- parse `document_types`, `flows`, `conventions`, `gates`, `rules`
2. **Build type registry**: For each entry in `document_types[]`, store: `id`, `name`, `id_prefix`, `template`, `instructions`, `fields`, `links_to`, `external`, `source`
3. **Build flow registry**: For each entry in `flows`, store: flow name, `root_type`, `steps[]` (with `type`, `depends_on`, `soft_depends_on`, `required`, `on_update`, `on_upstream_update`, `approve_roles`, `repeatable`, `done_when`, `params`), `feature_types[]` (with `id`, `name`, `skip[]`)
4. **Check CLI availability** (once per session): Run `which gitcheck`. If available, prefer CLI commands with `--json` for queries. If not available, print once: "gitcheck CLI not found. Using fallback file-parsing mode. Install with: dotnet tool install -g gitcheck" and use file-parsing for all queries.
5. **Detect repo context**: Read current git branch. If branch matches a `conventions.feature_branch_pattern` or `conventions.branch_pattern`, extract the feature/root document ID for use as default context.

---

## Subcommand: `status`

**Usage**: `/spec status [DOCUMENT-ID]`

Shows pipeline progress. If a document ID is given, show that document's flow. If no ID, show all root documents across all flows.

### With CLI

```bash
gitcheck pipeline status --json
# or for a specific document:
gitcheck pipeline status DOCUMENT-ID --json
```

Parse JSON output and render in human-readable format (see Display Format below).

### Without CLI (fallback)

1. For each flow in the flow registry, identify its `root_type`
2. Find the corresponding `document_types[]` entry to get the `id_prefix`
3. Scan the specs directory for files matching that prefix (e.g., `specs/features/FEAT-*.md`, `specs/releases/REL-*.md`)
4. For each root document found:
   a. Determine the flow by matching the document's type to a flow's `root_type`
   b. Get the steps for that flow
   c. If the document has a `feature_type` field (from its frontmatter), check the flow's `feature_types[]` for a matching entry and apply its `skip[]` list
   d. For each non-skipped step, determine status using PR state:

```bash
gh pr list --search "{ROOT_ID}" --state all --json number,state,title,labels,reviewDecision,mergedAt,url
```

**Step status rules:**
- `done` = PR with label `spec:{step_type}` is merged
- `needs-work` = PR open + reviewDecision is CHANGES_REQUESTED
- `approved` = PR open + reviewDecision is APPROVED
- `awaiting-review` = PR open + no review decision yet
- `in-progress` = PR open (general)
- `not started` = no PR, no branch for this step
- `locked` = at least one entry in `depends_on` is not `done`

For steps with `required: false`, show them but mark as `(optional)`.

### Display Format

```
{ROOT_ID}: {title} [{feature_type}, {priority}]
  {status_icon} {step_type}    -> {artifact} ({PR info})
  ...

Legend: filled-circle=done, half-circle=in-progress, empty-circle=pending, lock=locked
```

When showing all root documents, add a summary:

```
Pipeline Summary: N {flow_name} documents
  {ROOT_ID}: X/Y done, Z in-progress
  ...

  Action needed:
    {ROOT_ID}: PR #N awaiting review, PR #M has K unresolved comments
```

---

## Subcommand: `validate`

**Usage**: `/spec validate`

Runs integrity checks across all spec documents.

### With CLI

```bash
gitcheck specs validate --json
```

Parse JSON and render grouped by severity: ERROR first, then WARN, then OK.

### Without CLI (fallback)

1. Read `specs/pipeline.yaml` for `document_types` and `id_prefix` conventions
2. Read `specs/link-types.yaml` for valid link types and their properties
3. Scan all `.md` files in specs/ subdirectories
4. Parse frontmatter of each file, extract `id:` and `links:` section
5. Run these checks:
   - **Outgoing link targets exist**: every ID in `links:` points to an existing document
   - **Symmetric links**: if A has `related_to: [B]`, then B must have `related_to: [A]` (check symmetry rules from link-types.yaml)
   - **Dependency cycles**: no circular `depends_on` chains
   - **Origin consistency**: documents with `originated_from` links -- target exists and has appropriate status
   - **Orphaned documents**: documents with no `belongs_to` link (not connected to any parent)
   - **ID uniqueness**: no duplicate IDs across all document types
   - **ID format**: IDs match the `id_prefix` convention from pipeline.yaml `document_types[]`
   - **Link types valid**: all relationship names in `links:` exist in `specs/link-types.yaml`

### Display Format

```
Spec Integrity Report
=====================
Documents: N ({type counts})
Outgoing links: N total
Computed reverse links: N total

{severity} {check description}
...
```

If errors found, suggest: "Run `/spec next` to address issues."

---

## Subcommand: `next`

**Usage**: `/spec next [DOCUMENT-ID]`

Determines the next unlocked step for a root document and offers to execute it.

### Process

1. If no ID given, scan all root documents (same as `status`) and list those with pending steps. Ask which to advance.
2. If ID given, read the root document and determine its flow (by matching document type to a flow's `root_type`).
3. Determine current pipeline state (same status detection as `status` subcommand).
4. If the root document has a `feature_type` field, check the flow's `feature_types[]` for a `skip[]` list and exclude those step types.
5. Apply decision logic:

| State | Action |
|---|---|
| A step has PR with `needs-work` | Run the `inbox` subcommand for that PR |
| A step has PR `approved` | Suggest merging the PR |
| A step has PR `awaiting-review` | Show PR link, remind to review |
| Multiple steps unlocked | List all, ask which to do first |
| One step is next | Offer to execute it |
| All steps done | Suggest final merge of feature branch to main (only if allowed by `conventions.final_merge.requires`) |

6. **Cascade check** before executing: Run the `cascade` logic (see below) for the target step. If upstream documents are stale, warn and ask whether to update them first.

7. **Execute the chosen step**:
   a. Look up the step's `type` in `document_types[]` to find `instructions` and `template` paths
   b. Read the instruction file -- this tells the agent HOW to produce the document
   c. Read the template file -- this defines the STRUCTURE of the output
   d. Read ALL upstream documents in the dependency chain (walk `depends_on` recursively through the flow's steps, reading the corresponding documents)
   e. Read the root document itself for context
   f. Read `CLAUDE.md` and `AGENTS.md` for project constraints
   g. Determine the target directory from the document type's existing files (scan specs/ for files with matching `id_prefix`)
   h. Generate the next available ID: scan existing files with the type's `id_prefix`, find the highest number, increment
   i. For steps with `external: true` (like implementation), the output is code changes, not a spec document -- follow the instruction file's guidance
   j. For steps with `source: api`, the step involves external data (like test execution results) -- follow the instruction file

8. **Branching** (read patterns from `conventions`):
   a. Determine the feature branch name using `conventions.feature_branch_pattern` (replace `{FEATURE_ID}` with the root document's ID, e.g., `feat/FEAT-031`)
   b. Determine the step branch name using `conventions.branch_pattern` (replace `{FEATURE_ID}` and `{STEP_TYPE}`, e.g., `feat/FEAT-031-requirements`)
   c. Check `conventions.merge_strategy` for this step type:
      - `direct_to_main`: branch from main, PR to main
      - `feature_branch`: branch from the feature branch, PR to the feature branch
   d. Create the step branch from the appropriate base
   e. Write the document, commit, create PR:

```bash
gh pr create \
  --base {target_branch} \
  --title "feat(spec): {DOC_ID} {step_type} for {ROOT_ID}" \
  --label "spec,spec:{step_type}" \
  --body "{review checklist from instruction file}"
```

9. **After completion**: Run `gitcheck pipeline advance {ROOT_ID}` to automatically update the root document's status based on pipeline progress. Then show updated status, check if new steps are now unlocked, offer to continue.

### Automatic Status Transitions

The CLI automatically transitions root document `status` fields based on pipeline state. Transition rules are defined in `pipeline.yaml` per flow under `transitions[]` and `terminal_states[]`.

After each step is merged, run:

```bash
gitcheck pipeline advance {ROOT_ID}
```

This will:
- Transition `draft` → `in-progress` when the first step is done (`any_step_done`)
- Transition `in-progress` → `review` when all required steps are done (`all_steps_done`)
- Transition `review` → `done` when `--merged` flag is passed after final merge

For dry-run preview: `gitcheck pipeline advance {ROOT_ID} --dry-run`
For all features at once: `gitcheck pipeline advance --all`

**Do NOT manually edit the `status:` field in frontmatter** — let the CLI handle it via `pipeline advance`.

### Feature/Root Document Completion

When all required steps are done:
- Run `gitcheck pipeline advance {ROOT_ID}` — this will transition status to `review`
- Check `conventions.final_merge.requires` -- all listed step types must be `done`
- If satisfied, offer to create final merge PR: feature branch to main with `conventions.final_merge.strategy` (e.g., squash)
- After final merge, run `gitcheck pipeline advance {ROOT_ID} --merged` to transition to `done`
- If NOT satisfied, show what is missing and block the merge suggestion

**CRITICAL**: Never suggest final merge if required steps (from `conventions.final_merge.requires`) are not complete.

---

## Subcommand: `graph`

**Usage**: `/spec graph ID`

Shows the dependency tree for a document.

### With CLI

```bash
gitcheck specs graph ID --json
```

Parse JSON and render as an ASCII dependency tree.

### Without CLI (fallback)

1. Read the document's frontmatter for `links:`
2. For each linked document, recursively read its links
3. Build a tree and render:

```
FEAT-031: Universal /spec skill
  +-- belongs_to: EPIC-002
  +-- related_to: FEAT-029
  +-- REQ-031 (requirements)
  |   +-- belongs_to: FEAT-031
  +-- ARCH-031 (architecture)
      +-- belongs_to: FEAT-031
```

---

## Subcommand: `linked`

**Usage**: `/spec linked ID [--depth N]`

Shows impact radius -- all documents connected within N hops (default 2).

### With CLI

```bash
gitcheck specs linked ID --depth N --json
```

### Without CLI (fallback)

1. Start from the given document
2. BFS traversal through both outgoing links and computed reverse links up to depth N
3. Render as a table showing document, relationship, and hop distance

---

## Subcommand: `list`

**Usage**: `/spec list [type]`

Lists all spec documents, optionally filtered by a document type id from pipeline.yaml.

### With CLI

```bash
gitcheck specs list --json
# or filtered:
gitcheck specs list --type {type} --json
```

### Without CLI (fallback)

1. If `type` is given, find the matching `document_types[]` entry and its `id_prefix`
2. Scan the appropriate directory for files with that prefix
3. If no type given, scan all specs/ subdirectories
4. Parse frontmatter for id, title, status
5. Display as a table grouped by type

If the `type` argument does not match any `document_types[].id`, list available types:

```
Unknown document type "{type}". Available types:
  epic, idea, feature, design, research, requirements, architecture,
  test-case, implementation, documentation, execution, release, release-notes
```

---

## Subcommand: `new`

**Usage**: `/spec new <type> [title]`

Creates a new document of any type defined in `pipeline.yaml`.

### Process

1. Look up `<type>` in `document_types[]` by `id`. If not found, list available types and abort.
2. Read the `instructions` file for that type (from `document_types[].instructions`)
3. Read the `template` file for that type (from `document_types[].template`)
4. If no title provided, ask the user for one.
5. Determine directory: find existing documents with this type's `id_prefix` to discover the directory. If none exist, derive from the type id (e.g., type `feature` -> `specs/features/`, type `test-case` -> `specs/test-cases/`). Check the directory actually exists.
6. Generate the next ID: scan files matching `{id_prefix}-*.md` in the directory, find the highest numeric suffix, increment by 1. Format with zero-padding to match existing conventions (e.g., `FEAT-032`, `IDEA-045`).
7. Generate the document following the template structure and instruction guidance.
8. Handle branching based on document type:
   - If this type is a flow's `root_type` (e.g., `feature` is root of `feature` flow): check `conventions.merge_strategy` for this type. If `direct_to_main`, create branch from main, write file, commit, create PR to main.
   - If this type is NOT a root type: it is a pipeline step. Determine the parent/root document (ask user if not obvious), create branch per `conventions.branch_pattern`, PR to the feature branch per `conventions.merge_strategy`.
   - Special cases: types like `idea` and `epic` that have no flow -- commit directly to current branch (ideas are lightweight, no PR needed), or create a simple PR to main.

9. For types with `fields:` defined, populate them in frontmatter based on user input or sensible defaults.
10. For types with `links_to:` defined, ask the user for the parent document to link to (e.g., an idea links to an epic, a feature links to an epic).

### PR creation for pipeline step documents

```bash
gh pr create \
  --base {target_branch} \
  --title "feat(spec): {DOC_ID} {type_name} for {PARENT_ID}" \
  --label "spec,spec:{type_id}" \
  --body "{review checklist based on instruction file}"
```

---

## Subcommand: `link`

**Usage**:
- `/spec link <FROM> <TYPE> <TO>` -- add a link
- `/spec link --remove <FROM> <TYPE> <TO>` -- remove a link
- `/spec link --list ID` -- list links for a document

### Add a link

1. Read `specs/link-types.yaml` to validate the relationship type
2. Verify both documents exist (find files by scanning specs/ for matching IDs)
3. Read the source document's frontmatter
4. Add the link to its `links:` section under the given type
5. If the link type is symmetric (check `link-types.yaml`), also add the reverse link to the target document
6. Run `recompute` logic to update `reverse_links:` across affected documents

### Remove a link

1. Read source document, remove the link from frontmatter
2. If symmetric, also remove from target document
3. Run `recompute` logic

### List links

1. Read the document's frontmatter for outgoing links
2. Scan all documents in specs/ to find incoming links (where this document's ID appears in other documents' `links:`)
3. Display:

```
{DOC_ID}: {title}
  Outgoing:
    {link_type}: {TARGET_ID}, {TARGET_ID}
    ...
  Incoming (computed):
    {inverse_type}: {SOURCE_ID}, {SOURCE_ID}
    ...
```

---

## Subcommand: `cascade`

**Usage**: `/spec cascade [ID]`

Checks upstream documents for staleness and offers to update them.

### Process

1. If ID given, use that root document. If not, detect from current branch or ask.
2. Determine the flow for this document.
3. For each step in the flow (in dependency order):
   a. Find the corresponding document (if it exists)
   b. Get its last modification date (git log for last commit touching that file)
   c. For each downstream step that `depends_on` this step:
      - Find the downstream document
      - Get its creation/last-modification date
      - If upstream was modified AFTER downstream was created/last-modified, flag it as stale

4. Display findings:

```
Cascade Check for {ROOT_ID}
  requirements (REQ-031) modified 2026-03-28
    -> architecture (ARCH-031) created 2026-03-25 -- STALE (upstream updated after creation)
    -> test-cases (TC-031-*) created 2026-03-26 -- STALE
  architecture (ARCH-031) modified 2026-03-25
    -> (no downstream yet)
```

5. For each stale document, offer to update it:
   - Read the upstream document to see what changed
   - Read the stale downstream document
   - Propose specific updates
   - If user confirms, create branch, update, commit, PR (same branching flow as `next`)

---

## Subcommand: `inbox`

**Usage**: `/spec inbox`

Checks open spec PRs for unresolved review comments.

### Process

1. Find open PRs with spec labels:

```bash
gh pr list --label "spec" --state open --json number,title,labels,reviewDecision,url
```

2. For each PR, fetch comments:

```bash
# Inline review comments
gh api repos/{owner}/{repo}/pulls/{number}/comments --jq '.[] | {id, path, line, body, user: .user.login, created_at, in_reply_to_id}'

# PR-level reviews
gh api repos/{owner}/{repo}/pulls/{number}/reviews --jq '.[] | {id, state, body, user: .user.login}'

# Issue-style comments
gh pr view {number} --comments --json comments
```

3. Filter actionable comments (skip: bot comments, resolved threads, pure acknowledgments like "LGTM", "+1").

4. For each actionable comment, decide:

| Comment type | Action |
|---|---|
| Change request on spec text | Edit file, commit, push, reply with what changed |
| Question about a decision | Reply with explanation referencing upstream docs |
| Suggestion block | Apply if correct, explain if not |
| Request for missing content | Add content, commit, push, reply |
| Disagreement with approach | Reply with trade-off analysis, ask reviewer to decide |

5. After processing all comments:

```bash
# If all addressed, request re-review
gh pr edit {number} --remove-label "spec:needs-work" --add-label "spec:ready-for-review"
```

### Display Format

```
Spec Inbox: N PRs with pending comments

PR #{number}: {title} ({labels})
  comment-icon @{user} ({time_ago}): "{comment_body_truncated}"
  ...
  -> Action: {proposed action}
```

### Rules

- Always commit and push changes before replying to comments
- Reference the commit SHA in replies so reviewer can see the diff
- If unsure about a comment, ask for clarification
- Never dismiss a review -- only the reviewer should dismiss
- If a comment requires scope beyond the current step, flag it and suggest a new issue or upstream doc update

---

## Subcommand: `recompute`

**Usage**: `/spec recompute`

Recomputes `reverse_links:` in all documents by scanning outgoing links.

### Process

1. Read `specs/link-types.yaml` for inverse relationship names
2. Scan all `.md` files in specs/ subdirectories
3. Parse frontmatter, extract `id:` and `links:` section
4. Build reverse link map: for each outgoing link `A --rel--> B`, look up the inverse name in link-types.yaml, add to B's reverse links
5. Update `reverse_links:` section in each document's frontmatter
6. Report: "Recomputed reverse links for X documents, Y reverse links total"

### Rules

- Never modify `links:` section -- only `reverse_links:`
- Sort arrays alphabetically
- Empty reverse links = `reverse_links: {}`
- Include comment `# Incoming links (auto-computed, do not edit)` above reverse_links

---

## Flow Selection Logic

When a document ID is provided (e.g., `FEAT-029`, `REL-001`):

1. Extract the prefix from the ID (everything before the last `-` and digits, e.g., `FEAT` from `FEAT-029`)
2. Find the `document_types[]` entry whose `id_prefix` matches this prefix -- this gives the document's `type id` (e.g., `feature`)
3. Find the flow whose `root_type` matches this type id (e.g., flow `feature` has `root_type: feature`)
4. If no flow has this type as `root_type`, the document is not a flow root -- look up its `links_to` to find the parent, then determine the flow from the parent's type
5. Use this flow's `steps[]` for all pipeline operations

### Feature Type Handling

Some flows define `feature_types[]` with `skip[]` lists. When processing a root document:

1. Read the document's frontmatter for any field that matches a feature type discriminator (e.g., `feature_type: bug`)
2. Find the matching entry in the flow's `feature_types[]`
3. Apply the `skip[]` list -- those step types are excluded from status display, next-step logic, and completion checks

---

## Branching Conventions

All branching patterns come from `conventions` in pipeline.yaml:

- `feature_branch_pattern`: pattern for the main feature branch (e.g., `feat/{FEATURE_ID}`)
- `branch_pattern`: pattern for step-level branches (e.g., `feat/{FEATURE_ID}-{STEP_TYPE}`)
- `merge_strategy`: per step-type, either `direct_to_main` or `feature_branch`
- `final_merge`: conditions and strategy for merging the feature branch to main

**Variable substitution** in patterns:
- `{FEATURE_ID}` -- the root document's full ID (e.g., `FEAT-031`)
- `{STEP_TYPE}` -- the step type id from the flow (e.g., `requirements`, `architecture`)

When creating branches:
1. Read `merge_strategy` for the current step type
2. If `direct_to_main`: create step branch from `main`, PR targets `main`
3. If `feature_branch`: create step branch from the feature branch, PR targets the feature branch
4. Always ensure the base branch exists locally (fetch from origin if needed)

---

## Error Handling

- **Missing pipeline.yaml**: "No specs/pipeline.yaml found. This skill requires a pipeline configuration. See docs for setup."
- **Unknown document type**: List available types from pipeline.yaml
- **Unknown document ID**: "Document {ID} not found. Run `/spec list` to see all documents."
- **Missing instruction/template file**: "Instruction file {path} not found for type {type}. Check pipeline.yaml configuration."
- **gh CLI not available**: For PR-dependent operations, warn: "gh CLI not found. PR status detection unavailable. Showing file-based status only."
- **No git repo**: "Not in a git repository. Spec operations require git."

---

## Context Discipline

**CRITICAL: Stay focused on the current pipeline step. Do not expand scope.**

When executing a pipeline step (e.g., writing requirements for FEAT-031), the user may ask to:
- Fix something unrelated they just noticed
- Add a feature that came up during discussion
- Refactor code outside the current step's scope
- Investigate a tangent

**In all these cases, do NOT switch context.** Instead:

1. Acknowledge the request
2. Suggest creating a separate document: "This looks like a separate [idea/bug/feature/task]. Want me to run `/spec new <type>` to capture it?"
3. Continue with the current step

**Why:** Context switching mid-step leads to incomplete documents, mixed commits, and broken branches. Each concern deserves its own document with its own pipeline flow.

**Exception:** If the tangent is a blocker for the current step (e.g., a bug that prevents implementation), create the bug document first via `/spec new bug`, then return to the current step.

---

## Implementation Notes

- The skill reads pipeline.yaml ONCE at the start and uses the parsed data throughout
- No document types, step names, ID prefixes, or directory names are hardcoded
- All behavior is derived from pipeline.yaml + instruction files + template files
- The skill works on ANY repository with a `specs/` directory and `pipeline.yaml`
- When multiple flows exist, the skill handles each independently based on the document's type
- Steps with `params:` (like release flow's repeated execution/implementation steps) are distinguished by their parameter values when checking status
