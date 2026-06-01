# GitHub Pages with MkDocs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish interview-prep markdown articles as a GitHub Pages site using MkDocs with Material theme.

**Architecture:** Standard MkDocs site with articles grouped by 5 topic sections in the sidebar. Single `docs/` directory contains all content. Deploy to `gh-pages` branch via `mkdocs gh-deploy`.

**Tech Stack:** Python, MkDocs, mkdocs-material, GitHub Pages

---

### Task 1: Install Dependencies

**Files:** None

- [ ] **Create and activate virtual environment**

Run: `python3 -m venv .venv && source .venv/bin/activate`

Expected: virtual environment created in `.venv/`.

- [ ] **Add .venv to .gitignore**

Append `.venv/` to `.gitignore`. Create the file if it doesn't exist.

- [ ] **Install mkdocs and mkdocs-material**

Run: `pip install mkdocs mkdocs-material`

Expected: both packages install successfully into the venv.

- [ ] **Verify installation**

Run: `mkdocs --version`
Expected: outputs version (e.g., `mkdocs, version 1.6.1`)

- [ ] **Commit**

```bash
git add .gitignore .venv && git commit -m "chore: add mkdocs and mkdocs-material to venv"
```

### Task 2: Restructure Files into docs/

**Files:**
- Move: `articles/` → `docs/articles/`
- Move: `docker-supply-chain.md` → `docs/docker-supply-chain.md`

- [ ] **Move articles directory**

Run: `mkdir -p docs/articles && git mv articles/* docs/articles/`

Expected: `docs/articles/` contains all 28 `.md` files, original `articles/` directory gone.

- [ ] **Move root markdown file**

Run: `git mv docker-supply-chain.md docs/docker-supply-chain.md`

Expected: `docs/docker-supply-chain.md` exists.

- [ ] **Commit**

```bash
git add -A && git commit -m "chore: restructure markdown files under docs/"
```

### Task 3: Create Landing Page

**Files:**
- Create: `docs/index.md`

- [ ] **Write docs/index.md**

```markdown
# Docker Supply Chain — Interview Prep

Collection of articles on container supply chain security, image hardening, and Docker's security strategy.

## Topics

- **[Supply Chain Security Theory](articles/01-slsa-framework.md)** — SLSA, in-toto, SBOM, Sigstore, trusted builds
- **[Container Image Hardening](articles/08-distroless-images.md)** — distroless, seccomp, capabilities, AppArmor
- **[Helm Chart Security](articles/16-securitycontext-vs-podsecuritycontext.md)** — SecurityContext, Pod Security Standards, admission control
- **[CVE Lifecycle](articles/20-scanner-internals.md)** — scanners, CVSS, EPSS, fix categorization
- **[Docker Product & Strategy](articles/25-docker-scout.md)** — Scout, DHI, Notary, supply chain platform

[Browse the full topic map →](docker-supply-chain.md)
```

- [ ] **Commit**

```bash
git add docs/index.md && git commit -m "feat: add landing page"
```

### Task 4: Create mkdocs.yml

**Files:**
- Create: `mkdocs.yml`

- [ ] **Write mkdocs.yml**

```yaml
site_name: Docker Supply Chain
site_description: Interview prep articles on container supply chain security
theme:
  name: material
  features:
    - navigation.sections
    - navigation.top
    - toc.follow
    - search.highlight
nav:
  - Home: index.md
  - Docker Supply Chain Overview: docker-supply-chain.md
  - Supply Chain Security Theory:
    - articles/01-slsa-framework.md
    - articles/02-in-toto-attestations.md
    - articles/03-sbom.md
    - articles/04-sigstore.md
    - articles/05-dependency-management-security.md
    - articles/06-trusted-builds.md
    - articles/07-notary-docker-content-trust.md
  - Container Image Hardening:
    - articles/08-distroless-images.md
    - articles/09-image-minimization.md
    - articles/10-non-root-execution.md
    - articles/11-linux-capabilities.md
    - articles/12-seccomp.md
    - articles/13-apparmor-selinux.md
    - articles/14-readonly-filesystem.md
    - articles/15-multi-arch-security.md
  - Helm Chart Security:
    - articles/16-securitycontext-vs-podsecuritycontext.md
    - articles/17-pod-security-standards.md
    - articles/18-adapting-upstream-helm-charts.md
    - articles/19-admission-control.md
  - CVE Lifecycle:
    - articles/20-scanner-internals.md
    - articles/21-cve-sources.md
    - articles/22-cvss-epss.md
    - articles/23-fix-categorization.md
    - articles/24-coordinated-disclosure.md
  - Docker Product & Strategy:
    - articles/25-docker-scout.md
    - articles/26-docker-hardened-images.md
    - articles/27-docker-content-trust.md
    - articles/28-docker-supply-chain-platform.md
markdown_extensions:
  - toc:
      permalink: true
```

- [ ] **Commit**

```bash
git add mkdocs.yml && git commit -m "feat: add mkdocs config with material theme and grouped nav"
```

### Task 5: Verify Locally

**Files:** None

- [ ] **Serve the site locally**

Run: `mkdocs serve`
Expected: starts dev server on `http://127.0.0.1:8000`. Open in browser and verify:
  - Landing page renders
  - Sidebar shows grouped sections
  - Clicking articles navigates correctly
  - Search works

Stop the server with Ctrl+C after verification.

### Task 6: Deploy to GitHub Pages

**Files:** None

- [ ] **Build and deploy**

Run: `mkdocs gh-deploy`

Expected: builds site to `site/`, pushes to `gh-pages` branch on origin.

- [ ] **Verify deployment**

Visit `https://<username>.github.io/<repo>/` in browser. Verify the same checks as Task 5.

### Task 7: Commit Final Changes

- [ ] **Commit the docs/ directory and mkdocs.yml**

```bash
git add mkdocs.yml docs/ && git commit -m "feat: add mkdocs site with articles"
```

(If `mkdocs serve` or `gh-deploy` created a `site/` directory, add it to `.gitignore` first.)
