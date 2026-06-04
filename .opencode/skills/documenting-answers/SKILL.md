---
name: documenting-answers
description: Use when the user asks a follow-up question that deepens or extends documented topics, or when conversation reveals information worth capturing in project documentation
---

# Documenting Answers

## Overview

When conversation reveals information worth preserving, capture it in the project docs immediately — expand existing sections, create new articles, or reorganize groups. The work runs in a subagent so the main conversation continues uninterrupted.

## When to Use

**Hard triggers (fire unconditionally — no judgment call):**
- User says "update docs", "capture this", "document this", "write this up", or "add this to docs"
- User says "summarize and update" or "summarize and document"
- User provides a substantive correction or clarification about content in an existing doc
- User asks a follow-up question that reveals a gap, omission, or oversimplification in existing
  docs (e.g., "what about X?" when X is related but absent, or "isn't that the same problem?")

**Soft triggers (fire unless clearly not applicable):**
- User says "why", "explain", or "dive deep" about a documented topic
- User asks "what is <concept>" — any definitional question, not just Linux/container topics
- User provides technical detail, context, or real-world experience worth recording

**Do NOT use for:**
- Transient debugging context or build-specific quirks
- Questions where the answer is speculative

## Workflow

1. **Answer:** Answer the user's question directly
2. **Create branch + worktree:** Derive a slug from the topic, create `docs/<slug>` branch
   from `main`, and add a worktree at `.worktrees/docs/<slug>/`. See "Branch slug derivation"
   below.
3. **Propose:** Launch a subagent to read relevant docs (inside the worktree) and produce a
   written proposal of what to change (no edits yet). For "what is" questions, include a
   cross-reference grep in the proposal.
4. **Present:** Print the proposed changes to the user
5. **Approve:** Ask the user to approve the proposal
6. **Publish:** On approval, apply edits in the worktree, verify, commit, rebase onto latest
   upstream/main (with AI conflict resolution), merge into main, push, deploy, and clean up.
   If the user declines, clean up the branch and worktree instead.

## Where to Document Information

The answer is a detail within a broader topic. Find the broader topic first, then fit the
information into it.

STRICT priority:

1. **Expand the existing article that covers the broader topic** — preferred 90% of the time.
   The answer fills a gap within a larger subject (e.g., chroot → container isolation in Docker
   Architecture; ptrace → syscall filtering in seccomp). Add a subsection within the relevant
   section.
2. **Create a new article for the broader topic** — only when the broader topic itself is
   missing from the docs. The answer becomes one section within the new article.

## Cross-Reference Update Rule

When the answer introduces or clarifies a concept: find every existing reference to the concept
in `docs/articles/**/*.md` and make the concept name itself an inline hyperlink to the new
canonical location. No "see also" footnotes — the concept word **is** the link.

### Good (inline hypertext):
```markdown
The command runs inside this [chroot](../articles/docker/docker-architecture.md#chroot-and-pivot_root).
```

```markdown
...why [ptrace](../articles/container-image-hardening/seccomp.md#ptrace) is dangerous...
```

### Bad (separate "see also"):
```
...ptrace... — see seccomp's ptrace section for details
...chroot() — see Docker Architecture for more
```

Use `replaceAll` when the concept name appears as a plain word and every instance should link.
Use targeted edits when only specific mentions should link, or when the word is part of a larger
identifier (e.g., `CAP_SYS_PTRACE` — link only the `ptrace` portion, or the whole term as
context dictates). When the mention is already part of a link, leave it unchanged.

## Subagent: Research & Propose

Dispatch a subagent to determine what docs need updating and produce a concrete proposal. The
subagent should **read only** — no edits. Point it at the worktree path so it reads docs
from the isolated checkout.

```markdown
The user just asked: "<question>"

I answered with: "<answer>"

The project at <project-root> is an MkDocs site. The branch <branch> has already been
created with a worktree at <worktree-path>. Read docs from the worktree.

Currently documented topics (from mkdocs.yml nav):
<list nav sections and their articles>

Read the docs relevant to this follow-up, then produce a written proposal.

STRICT priority — only move to the next option if the previous one doesn't fit:
1. **Expand an existing section with new detail** — prefer this 90% of the time
2. **Add a new section to an existing article** — only if the content is too large or
   tangential for an existing section
3. **Create a new article in an existing nav group** — requires strong justification: must be a
   substantial topic (>300 lines) that doesn't fit any existing article. When in doubt, expand
   an existing section instead.
4. **Create a new nav group** — almost never. Only when the topic genuinely doesn't fit any
   existing group and represents a new category.

Your proposal must include:
- **What file(s) to change** (relative path)
- **Where in each file** (after which section or at what anchor point)
- **What content to add** (full markdown)
- **Whether mkdocs.yml needs updating** (new nav entry or new group)
- **Whether docs/index.md needs updating** (new entry in Topics list)
- **Whether docs/docker-supply-chain.md needs updating** (new entry in Topic Map)
- **A git commit message** for the change
- **Priority level justification** — which of the 4 priorities above, and why

If the answer introduces or clarifies a concept, also grep for all existing mentions across
docs/articles/**/*.md and include a cross-reference update plan:
- **All files that mention the concept** (grep output)
- **Which mentions should become inline hypertext** and what anchor to link to
- **Which mentions should stay as-is** (already part of a link, or in a context where
  linking doesn't make sense)

Do NOT edit any files. Only report the proposal back.
```

## Approval Prompt Template

After the proposal comes back, present it to the user:

```
This follow-up adds information that should be captured in the docs.

Proposed changes:
- <file>: <description of change> (e.g. "add musl vs glibc section after 'Why Distroless
  Reduces CVEs'")

Proposed content:
<proposed markdown>

Cross-reference updates:
- <file>: <concept> → <link target>
- <file>: <concept> → <link target>

Commit message: <proposed message>

Apply these changes? (yes/no)
```

Wait for the user's response. Only proceed to Apply & Publish on explicit approval.

## Branch slug derivation

Derive the slug from the topic name — the topic is the subject of the user's question
(e.g., "what about build args?" → slug is `build-args`).

```python
slug = re.sub(r'[^a-z0-9]+', '-', topic.lower()).strip('-')
branch = f"docs/{slug}"
worktree = f".worktrees/docs/{slug}"
```

## Subagent: Publish (branch + worktree)

After the user approves, dispatch a subagent to apply edits in the already-created worktree,
verify, commit, rebase, merge, push, deploy, and clean up.

### Dispatch template

```markdown
Apply the approved documentation changes using the branch + worktree workflow.
The branch and worktree already exist — skip creation.

Project root: <project-root>
Branch: docs/<slug>
Worktree: <project-root>/.worktrees/docs/<slug>
Venv: <project-root>/.venv

Approved proposal: <paste approved proposal>

1. Apply edits in the worktree:
   Edit the files specified in the proposal within .worktrees/docs/<slug>/

2. Verify the build:
   cd <project-root>/.worktrees/docs/<slug>
   <project-root>/.venv/bin/mkdocs build --strict
   If this fails, report the failure to the user and STOP. Do NOT proceed.

3. Commit on the branch:
   cd <project-root>/.worktrees/docs/<slug>
   git add -A
   git commit -m "<proposed commit message>"

4. Fetch and rebase onto latest upstream/main:
   cd <project-root>/.worktrees/docs/<slug>
   git fetch upstream main
   git rebase upstream/main
   If no conflicts, proceed to step 5.

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

5. Merge into main:
   cd <project-root>
   git checkout main
   git merge docs/<slug> --no-ff -m "docs: merge <slug> (<commit message>)"

6. Push upstream main:
   git push upstream main

7. Deploy:
   cd <project-root>
   <project-root>/.venv/bin/mkdocs gh-deploy --remote-name upstream

8. Cleanup:
   git branch -d docs/<slug>
   git worktree remove .worktrees/docs/<slug>

Report back:
- Files changed (list)
- Build result (pass/fail)
- Conflict resolution (none | auto-resolved conflicts | reported to user)
- Deploy status (success URL or failure)
```

### Usage note

The branch and worktree are created before the propose subagent runs, so the publish
subagent can assume they already exist. Multiple documenting-answers sessions can run
simultaneously — each has its own `docs/<topic>` branch and
`.worktrees/docs/<topic>/` directory.

If the user declines the proposal, clean up instead of publishing:
```bash
git checkout main
git branch -D docs/<slug>
git worktree remove .worktrees/docs/<slug>
```

## Common Mistakes

- **Documenting everything:** Only capture information with lasting relevance. Not every answer
  belongs in docs.
- **Duplicating content:** Check if info already exists first. Merge rather than duplicate.
- **Forgetting nav updates:** New articles must be added to `mkdocs.yml` nav. The build check
  catches this.
- **Forgetting index and topic map:** New nav groups must be added to both `docs/index.md`
  (Topics list) and `docs/docker-supply-chain.md` (Topic Map sections). These are not checked
  by the build.
- **Creating articles too eagerly:** Always try to expand an existing section first. New
  articles are rarely needed — the content almost always fits inside an existing article. Only
  suggest a new article when the topic is truly standalone and can't be merged.
- **Over-organizing:** New groups are almost never needed. Topics almost always fit into an
  existing nav group.
- **Racing the user:** Show the proposal before applying. Let the user decide what's worth
  capturing.
- **Skipping cross-references:** Grepping all articles for the concept name and proposing
  inline hypertext links is mandatory. A concept documented in one place but referenced in five
  others without links is half-done.
- **Skipping the deploy:** Always run the full commit, push, and deploy cycle. Don't stop after
  editing.
- **Not cleaning up after failure:** If the publish subagent fails mid-way, branch and worktree
  persist. Manually clean up with:
  `git worktree remove .worktrees/docs/<slug> 2>/dev/null; git branch -D docs/<slug>`

## Verification

On approval, always dispatch the branch + worktree subagent to apply, verify, commit,
rebase, merge, push, and deploy. On decline, clean up the branch and worktree.
