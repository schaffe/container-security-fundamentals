---
name: documenting-answers
description: Use when the user asks a follow-up question that deepens or extends documented topics, or when conversation reveals information worth capturing in project documentation
---

# Documenting Answers

## Overview

When conversation reveals information worth preserving, capture it in the project docs immediately — expand existing sections, create new articles, or reorganize groups. The work runs in a subagent so the main conversation continues uninterrupted.

## When to Use

**Triggers:**
- User asks "what is <concept>" — a definitional question about a Linux, container, or Docker
  concept
- User asks a follow-up question that deepens a documented topic
- User's question reveals a topic not yet covered
- User provides detail, context, or clarification worth recording
- Conversation exposes a gap or omission in existing docs

**Do NOT use for:**
- Transient debugging context or build-specific quirks
- Questions where the answer is speculative
- Information already fully covered in existing docs

## Workflow

1. **Answer:** Answer the user's question directly
2. **Propose:** Launch a subagent to read relevant docs and produce a written proposal of what
   to change (no edits yet). For "what is" questions, include a cross-reference grep in the
   proposal.
3. **Present:** Print the proposed changes to the user
4. **Approve:** Ask the user to approve the proposal
5. **Publish:** On approval, dispatch **publishing-docs** subagent to apply, verify, commit,
   push, and deploy

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
in `docs/articles/*.md` and make the concept name itself an inline hyperlink to the new
canonical location. No "see also" footnotes — the concept word **is** the link.

### Good (inline hypertext):
```markdown
The command runs inside this [chroot](../articles/30-docker-architecture.md#chroot-and-pivot_root).
```

```markdown
...why [ptrace](../articles/12-seccomp.md#ptrace) is dangerous...
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
subagent should **read only** — no edits.

```markdown
The user just asked: "<question>"

I answered with: "<answer>"

The project at <project-root> is an MkDocs site.

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
docs/articles/*.md and include a cross-reference update plan:
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

## Subagent: Publish (uses publishing-docs)

After the user approves, dispatch a subagent using the **publishing-docs** skill to apply the
approved proposal, verify, commit, push, and deploy. See
`.opencode/skills/publishing-docs/SKILL.md`.

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

## Verification

On approval, always dispatch **publishing-docs** to apply, verify, commit, push, and deploy.
