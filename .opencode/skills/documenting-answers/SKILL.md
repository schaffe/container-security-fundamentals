---
name: documenting-answers
description: Use when the user asks a follow-up question that deepens or extends documented topics, or when conversation reveals information worth capturing in project documentation
---

# Documenting Answers

## Overview

When conversation reveals information worth preserving, capture it in the project docs immediately — expand existing sections, create new articles, or reorganize groups. The work runs in a subagent so the main conversation continues uninterrupted.

## When to Use

**Triggers:**
- User asks "what is <concept>" — a definitional question about a Linux, container, or Docker concept
- User asks a follow-up question that deepens a documented topic
- User's question reveals a topic not yet covered
- User provides detail, context, or clarification worth recording
- Conversation exposes a gap or omission in existing docs

**Do NOT use for:**
- Transient debugging context or build-specific quirks
- Questions where the answer is speculative
- Information already fully covered in existing docs

## Workflow

Two modes depending on the trigger:

### Mode A: "What is <concept>" questions

1. **Answer:** Answer the user's question directly and concisely
2. **Find & create:** Determine the best home for the concept explanation (see priority rules below). Create the content.
3. **Cross-reference:** Find every existing mention of the concept across all `docs/articles/*.md` and update those mentions to link to the new canonical explanation
4. **Verify:** Run `mkdocs build --strict`
5. **Publish:** Commit, push, and deploy (see verification + publish steps below)

### Mode B: Other follow-up questions

1. **Answer:** Answer the user's question directly
2. **Propose:** Launch a subagent to read relevant docs and produce a written proposal of what to change (no edits yet)
3. **Present:** Print the proposed changes to the user
4. **Approve:** Ask the user to approve the proposal
5. **Publish:** On approval, dispatch **publishing-docs** subagent to apply, verify, commit, push, and deploy

## Where to Document Concepts (Priority Order)

When documenting a "what is <concept>" answer, the concept is a detail within a broader topic. Find the broader topic first, then fit the concept into it.

STRICT priority:

1. **Expand the existing article that covers the broader topic the concept belongs to** — preferred 90% of the time. The concept is a detail within a larger subject (e.g., chroot → container isolation in Docker Architecture; ptrace → syscall filtering in seccomp). Add a subsection within the relevant section.
2. **Create a new article for the broader topic** — only when the broader topic itself is missing from the docs. The concept becomes one section within the new article. Don't create "concepts reference" articles; create topic articles (e.g., "Linux Namespaces" rather than "Key Linux Concepts").

## Cross-Reference Update Rule

After adding the concept explanation, find every existing reference to the concept in `docs/articles/*.md` and add a relative link to the new canonical location. Examples:

- `chroot` → `../articles/NN-key-concepts.md#chroot` or the relevant anchor
- `ptrace` → `../articles/NN-key-concepts.md#ptrace` or the relevant anchor

Use `replaceAll` when the concept name appears as a plain word and should link every time. Use targeted edits when only specific mentions should link. When the mention is already part of a link, leave it unchanged.

## Common Mistakes

- **Documenting everything:** Only capture information with lasting relevance. Not every answer belongs in docs.
- **Duplicating content:** Check if info already exists first. Merge rather than duplicate.
- **Forgetting nav updates:** New articles must be added to `mkdocs.yml` nav. The build check catches this.
- **Forgetting index and topic map:** New nav groups must be added to both `docs/index.md` (Topics list) and `docs/docker-supply-chain.md` (Topic Map sections). These are not checked by the build.
- **Creating articles too eagerly:** Always try to expand an existing section first. New articles are rarely needed — the content almost always fits inside an existing article. Only suggest a new article when the topic is truly standalone and can't be merged.
- **Over-organizing:** New groups are almost never needed. Topics almost always fit into an existing nav group.
- **Racing the user:** For Mode B, show the proposal before applying. Let the user decide what's worth capturing.
- **Skipping cross-references:** For Mode A, grepping all articles for the concept name and adding links is mandatory. A concept documented in one place but referenced in five others without links is half-done.
- **Skipping the deploy:** Always run the full commit, push, and deploy cycle. Don't stop after editing.

## Verification

On approval, always dispatch **publishing-docs** to apply, verify, commit, push, and deploy.
