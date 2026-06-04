# Container Supply Chain — Interview Prep

Collection of articles on container supply chain security, image hardening, and Docker's security strategy. Published via GitHub Pages using MkDocs with the Material theme.

**Site:** [https://schaffe.github.io/container-security-fundamentals/](https://schaffe.github.io/container-security-fundamentals/)

## Prerequisites

- Python 3.9+
- `python3-venv` (system package)

## Setup

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install mkdocs mkdocs-material
```

## Development

Serve the site locally with live reload:

```bash
source .venv/bin/activate
mkdocs serve
```

Open http://127.0.0.1:8000. Edits to `.md` files trigger an automatic rebuild.

## Build

```bash
source .venv/bin/activate
mkdocs build --strict
```

Output goes to `site/`. Use `--strict` to fail on warnings.

## Deploy

```bash
source .venv/bin/activate
mkdocs gh-deploy --remote-name <remote-name>
```

This builds the site and force-pushes to the `gh-pages` branch. GitHub Pages serves from there.

## Adding an Article

1. Drop a `.md` file into the appropriate topic subdirectory under `docs/articles/`
2. Add one entry to the appropriate section in `mkdocs.yml` under `nav`
3. Run `mkdocs build --strict` to verify
4. Deploy with `mkdocs gh-deploy`

## Project Structure

```
├── mkdocs.yml              # Site config (nav, theme, extensions)
├── docs/
│   ├── index.md            # Landing page
│   ├── docker-supply-chain.md  # Topic map
│   └── articles/           # 37 interview prep articles grouped by topic
│       ├── supply-chain-security/
│       ├── linux-fundamentals/
│       ├── container-image-hardening/
│       ├── kubernetes-security/
│       ├── cve-lifecycle/
│       └── docker/
│           └── product-strategy/
└── .venv/                  # Virtual environment (ignored)
```
