---
name: documenting-answers
description: Use when the user asks a follow-up question that deepens or extends documented topics, or when conversation reveals information worth capturing in project documentation
---

# Documenting Answers

## Overview

When conversation reveals information worth preserving, capture it in the project docs immediately — expand existing sections, create new articles, or reorganize groups. The work runs in a subagent so the main conversation continues uninterrupted.

## When to Use

**Triggers:**
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
2. **Propose:** Launch a subagent to read relevant docs and produce a written proposal of what to change (no edits yet)
3. **Present:** Print the proposed changes to the user
4. **Approve:** Ask the user to approve the proposal
5. **Publish:** On approval, dispatch **publishing-docs** subagent to apply, verify, commit, push, and deploy

## Subagent: Research & Propose

Dispatch a subagent to determine what docs need updating and produce a concrete proposal. The subagent should **read only** — no edits.

```markdown
The user just asked: "<question>"

I answered with: "<answer>"

The project at <project-root> is an MkDocs site.

Currently documented topics (from mkdocs.yml nav):
<list nav sections and their articles>

Read the docs relevant to this follow-up, then produce a written proposal.

Your proposal must include:
- **What file(s) to change** (relative path)
- **Where in each file** (after which section or at what anchor point)
- **What content to add** (full markdown)
- **Whether mkdocs.yml needs updating**
- **A git commit message** for the change

Do NOT edit any files. Only report the proposal back.
```

## Subagent: Publish (uses publishing-docs)

After the user approves, dispatch a subagent using the **publishing-docs** skill to apply the approved proposal, verify, commit, push, and deploy. See `.opencode/skills/publishing-docs/SKILL.md`.

## Approval Prompt Template

After the proposal comes back, present it to the user:

```
This follow-up adds information that should be captured in the docs.

Proposed changes:
- <file>: <description of change> (e.g. "add musl vs glibc section after 'Why Distroless Reduces CVEs'")

Proposed content:
```markdown
<full markdown of proposed addition>
```

Commit message: <proposed message>

Apply these changes? (yes/no)
```

Wait for the user's response. Only proceed to Apply & Publish on explicit approval.

## Common Mistakes

- **Documenting everything:** Only capture information with lasting relevance. Not every answer belongs in docs.
- **Duplicating content:** Check if info already exists first. Merge rather than duplicate.
- **Forgetting nav updates:** New articles must be added to `mkdocs.yml` nav. The build check catches this.
- **Over-organizing:** New groups are rare. Only create one when the topic genuinely doesn't fit any existing group.
- **Racing the user:** Show the proposal before applying. Let the user decide what's worth capturing.
- **Skipping the deploy:** Always use the **publishing-docs** skill for the apply + deploy step. Don't skip it.

## Verification

On approval, always dispatch **publishing-docs** to apply, verify, commit, push, and deploy.
