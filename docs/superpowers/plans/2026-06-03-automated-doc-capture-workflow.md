# Automated Doc Capture via Ephemeral Worktrees — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Modify `documenting-answers` to create ephemeral `docs/<topic>` branches + worktrees for parallel doc capture, with auto-rebase conflict resolution and merge-into-main deploy.

**Architecture:** After user approves a proposal, `documenting-answers` creates an isolated branch + worktree, applies edits there, verifies the build, commits, rebases onto latest upstream/main (with AI conflict resolution), merges into main, pushes, deploys, and cleans up.

**Tech Stack:** git worktrees, MkDocs, GitHub Pages

---

### Task 1: Add `.worktrees/` to `.gitignore`

**File:** `.gitignore`

- [ ] **Step 1: Append `.worktrees/` to `.gitignore`**

Edit `.gitignore` to add `.worktrees/`:

```
.venv/
.idea/
site/
.worktrees/
```

- [ ] **Step 2: Commit**

```bash
git add .gitignore
git commit -m "chore: ignore .worktrees/ directory"
```

---

### Task 2: Rewrite publish step in documenting-answers SKILL.md

**File:** `.opencode/skills/documenting-answers/SKILL.md`

Replace the current publish step (step 5 in Workflow) and the "Subagent: Publish" section with the new branch-based workflow.

#### Changes needed

**a) Update Workflow step 5 (line 38-39):**

Current:
```
5. **Publish:** On approval, dispatch **publishing-docs** subagent to apply, verify, commit,
   push, and deploy
```

New:
```
5. **Publish:** On approval, dispatch a subagent to create an ephemeral `docs/<slug>` branch +
   worktree, apply edits, verify, commit, rebase onto latest upstream/main (with AI conflict
   resolution), merge into main, push, deploy, and clean up
```

**b) Replace the "Subagent: Publish" section (lines 153-157):**

Current:
```
## Subagent: Publish (uses publishing-docs)

After the user approves, dispatch a subagent using the **publishing-docs** skill to apply the
approved proposal, verify, commit, push, and deploy. See
`.opencode/skills/publishing-docs/SKILL.md`.
```

New subagent dispatch section with the full worktree workflow template:

```
## Subagent: Publish (branch + worktree)

After the user approves, derive a branch slug from the topic and dispatch a subagent to
apply, merge, and deploy using an ephemeral branch + worktree.

### Branch slug derivation

```python
slug = re.sub(r'[^a-z0-9]+', '-', topic.lower()).strip('-')
branch = f"docs/{slug}"
worktree = f".worktrees/docs/{slug}"
```

### Dispatch template

```markdown
Apply the approved documentation changes using the branch + worktree workflow:

Project root: <project-root>
Branch: docs/<slug>
Worktree: <project-root>/.worktrees/docs/<slug>
Venv: <project-root>/.venv

Approved proposal: <paste approved proposal>

1. Create the branch and worktree:
   cd <project-root>
   git branch docs/<slug> main
   git worktree add .worktrees/docs/<slug> docs/<slug>

2. Apply edits in the worktree:
   Edit the files specified in the proposal within .worktrees/docs/<slug>/

3. Verify the build:
   cd <project-root>/.worktrees/docs/<slug>
   <project-root>/.venv/bin/mkdocs build --strict
   If this fails, report the failure to the user and STOP. Do NOT proceed.

4. Commit on the branch:
   cd <project-root>/.worktrees/docs/<slug>
   git add -A
   git commit -m "<proposed commit message>"

5. Fetch and rebase onto latest upstream/main:
   cd <project-root>/.worktrees/docs/<slug>
   git fetch upstream main
   git rebase upstream/main
   If no conflicts, proceed to step 6.

   If conflicts occur:
   a. Run `git diff --name-only --diff-filter=U` to list conflicted files
   b. For each conflicted file:
      - Read both sides: the branch's version (ours) and main's version (theirs)
      - Understand the intent of each change
      - Produce a merged version that preserves both contributions
      - If the changes on both sides touch the same lines with contradictory
        semantics and no clear resolution: STOP, report the specific conflict
        to the user, and do NOT continue
      - Otherwise: write the merged file, `git add <file>`
   c. `git rebase --continue`
   d. Repeat until rebase completes

6. Merge into main:
   cd <project-root>
   git checkout main
   git merge docs/<slug> --no-ff -m "docs: merge <slug> (<commit message>)"

7. Push upstream main:
   git push upstream main

8. Deploy:
   cd <project-root>
   <project-root>/.venv/bin/mkdocs gh-deploy --remote-name upstream

9. Cleanup:
   git branch -d docs/<slug>
   git worktree remove .worktrees/docs/<slug>

Report back:
- Files changed (list)
- Build result (pass/fail)
- Conflict resolution (none | auto-resolved conflicts | reported to user)
- Deploy status (success URL or failure)
```

### Usage note

The subagent reads the approved proposal and executes it in isolation. Multiple
subagents can run simultaneously — each has its own `docs/<topic>` branch and
`.worktrees/docs/<topic>/` directory.

- [ ] **Step 1: Apply edits to SKILL.md**

Apply the following edits:

1. Replace step 5 in Workflow section
2. Replace "Subagent: Publish" section

- [ ] **Step 2: Verify the file reads cleanly**

Run: `head -20 .opencode/skills/documenting-answers/SKILL.md` and confirm no syntax issues with the markdown.

- [ ] **Step 3: Commit**

```bash
git add .opencode/skills/documenting-answers/SKILL.md
git commit -m "feat: ephemeral docs/<topic> branches with worktree-based publish workflow"
```
