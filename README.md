# Artur's Knowledge Base

Engineering knowledge base and interview prep: container supply chain security, image hardening,
Docker's security strategy, and durable execution (Temporal architecture, internals, and
workflow-engine system design). Published via GitHub Pages using MkDocs.

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

## Verify

Run the site checks (strict build, no stale links to moved/renamed pages, nav structure):

```bash
MKDOCS_BIN=.venv/bin/mkdocs bash scripts/verify-site.sh
```

Prints one PASS/FAIL line per check; exits non-zero on any failure.

## Project Structure

```
├── mkdocs.yml              # Site config (nav, theme, extensions)
├── scripts/
│   └── verify-site.sh      # Site checks (strict build, links, nav)
├── docs/
│   ├── index.md            # Landing page (topic hub)
│   ├── container-security.md   # Container-security topic map
│   └── articles/           # 57 interview prep articles grouped by topic
│       ├── supply-chain-security/
│       ├── linux-fundamentals/
│       ├── container-image-hardening/
│       ├── kubernetes-security/
│       ├── cve-lifecycle/
│       ├── docker/
│       │   └── product-strategy/
│       └── durable-execution/
└── .venv/                  # Virtual environment (ignored)
```

Interview/system-design articles live inside their topic directory (e.g.
`durable-execution/design-a-workflow-engine.md`, `cve-lifecycle/cve-triage-system.md`)
rather than a separate interview section.
