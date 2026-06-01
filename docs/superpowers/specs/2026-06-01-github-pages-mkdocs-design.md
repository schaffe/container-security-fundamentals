# GitHub Pages with MkDocs — Design Doc

## Goal

Publish markdown interview-prep articles as a GitHub Pages site using MkDocs with the Material theme.

## Directory Structure

```
repo/
├── mkdocs.yml
└── docs/
    ├── index.md                  # landing page
    ├── docker-supply-chain.md    # topic map overview
    └── articles/
        ├── 01-slsa-framework.md
        ├── 02-in-toto-attestations.md
        ... (28 total)
```

All `.md` files move under `docs/`. No file renames.

## Configuration (`mkdocs.yml`)

- **Theme:** `material` with `navigation.sections`, `navigation.top`, `toc.follow`, `search.highlight`
- **Nav:** 5 grouped sections matching the topic map (Supply Chain Security Theory, Container Image Hardening, Helm Chart Security, CVE Lifecycle, Docker Product & Strategy), plus Home and Overview pages
- **Extensions:** `toc` with permalink enabled

## Landing Page (`docs/index.md`)

Minimal welcome page with one-line topic summaries linking to each section's first article, plus a link to the full topic map.

## Deployment

Run `mkdocs gh-deploy` — builds to `gh-pages` branch, GitHub Pages serves from there.

## Adding New Articles

1. Drop `.md` file into `docs/articles/`
2. Add one line to `mkdocs.yml` nav under the appropriate section
3. Run `mkdocs gh-deploy` to publish
