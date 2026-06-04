# Automated Doc Capture via Ephemeral Worktrees

## Motivation

When a user asks a follow-up question that warrants documentation, the
`documenting-answers` skill captures it. Currently it writes directly to the main
checkout. This prevents running multiple capture queries in parallel (you'd get
interleaved dirty state) and couples doc writing to the active workspace.

## Design

Introduce an ephemeral branch + worktree per capture session. The full lifecycle
is owned by `documenting-answers`; `publishing-docs` is unchanged.

### Branch naming

```
docs/<topic-slug>
```

Created from `main`. Deleted after merge.

### Worktree location

```
.worktrees/docs/<topic-slug>/
```

Project-local, added to `.gitignore` so worktree contents are never tracked.

### Lifecycle

```
User approves proposal
  → [create] git branch docs/<topic> main
              git worktree add .worktrees/docs/<topic> docs/<topic>

  → [apply]   write approved edits into .worktrees/docs/<topic>/docs/

  → [verify]  mkdocs build --strict (in worktree, using venv from main checkout)

  → [commit]  git add + git commit (in worktree)

  → [merge]   git checkout main
               git merge docs/<topic> (no-ff, with commit message)

  → [push]    git push upstream main

  → [deploy]  source .venv/bin/activate && mkdocs gh-deploy --remote-name upstream

  → [cleanup] git branch -d docs/<topic>
               git worktree remove .worktrees/docs/<topic>
```

### Ownership

- **documenting-answers** — creates branch + worktree, applies edits, runs the
  full merge→deploy→cleanup sequence
- **publishing-docs** — unchanged. Still used for standalone deploy requests
  from main.

### Error handling

- If `mkdocs build --strict` fails: report the failure to the user, do NOT
  proceed to commit/merge. Worktree remains for debugging.
- If merge has conflicts: report to user, leave worktree intact for manual
  resolution. Do NOT deploy.
- On any failure: stop and report. Do not auto-cleanup so state is inspectable.

### Parallelism

Multiple capturing queries can run simultaneously because each gets its own
`docs/<topic>` branch and worktree. There is no shared mutable state until merge
time, when each branch serializes on merging into `main`.

### Cleanup if interrupted

If the process fails mid-way, the branch and worktree persist. Manual cleanup:

```bash
git worktree remove .worktrees/docs/<topic> 2>/dev/null; git branch -D docs/<topic>
```

## Files changed

| File | Change |
|------|--------|
| `.gitignore` | Add `.worktrees/` |
| `.opencode/skills/documenting-answers/SKILL.md` | Rewrite publish step with worktree lifecycle |
