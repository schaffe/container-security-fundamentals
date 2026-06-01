---
name: publishing-docs
description: Use when approved documentation changes need to be applied, verified, committed, and deployed upstream via git and MkDocs
---

# Publishing Docs

## Overview

Takes an approved documentation proposal, applies edits to the MkDocs project, verifies the build, commits, pushes upstream, and deploys to GitHub Pages via `mkdocs gh-deploy`.

## Workflow

1. **Apply edits** as specified in the approved proposal
2. **Verify** with `mkdocs build --strict`
3. **Commit** with the proposed commit message
4. **Push** to `upstream main`
5. **Deploy** with `mkdocs gh-deploy --remote upstream`

## Dispatch Template

```markdown
Apply the approved documentation changes:

Approved proposal: <paste the approved proposal>

Project at /Users/artur/code/interview-prep

1. Edit files as specified in the proposal
2. Run `mkdocs build --strict` to verify
3. Commit with the proposed commit message
4. Run `git push upstream main`
5. Run `source .venv/bin/activate && mkdocs gh-deploy --remote upstream`

Report back: files changed, build result, and deploy status.
```

## Common Mistakes

- **Skipping verification:** Always run `mkdocs build --strict` before committing. A broken build wastes a deploy.
- **Wrong remote:** The remote is `upstream`, not `origin`. Check with `git remote -v` if unsure.
- **Wrong branch:** The default branch is `main`. Confirm before pushing.
- **Committing without verifying:** Build first, commit second.
