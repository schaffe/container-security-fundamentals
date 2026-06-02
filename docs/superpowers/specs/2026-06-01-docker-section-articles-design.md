# Docker Section — Article Design

## Purpose

Add a new "Docker" section to the container security interview prep site covering Docker fundamentals that underpin the existing security-focused articles. This fills a gap — the site has 29 security articles but no dedicated content on how Docker itself works.

## Articles

Seven articles in `docs/articles/`, numbered from 30:

| # | File | H1 | Topics | Target length |
|---|------|----|--------|--------------|
| 30 | `30-docker-architecture.md` | Docker Architecture | Client-server model, dockerd ↔ containerd ↔ containerd-shim ↔ runc, OCI runtime & image specs, Docker vs containerd vs CRI | ~400 lines |
| 31 | `31-build-context.md` | Build Context | What is the build context, `.dockerignore`, context size impact, how context is sent to the daemon/BuildKit | ~250 lines |
| 32 | `32-buildkit-internals.md` | BuildKit Internals | LLB (Low-Level Build), solver, parallelization, caching, `--secret`, `--ssh`, `--mount=type=cache`, frontends (dockerfile.v0) | ~500 lines |
| 33 | `33-how-docker-builds-images.md` | How Docker Builds Images | Full pipeline: Dockerfile → parser → AST → LLB → solver → layer export → image manifest → push | ~500 lines |
| 34 | `34-image-layers-storage-drivers.md` | Image Layers & Storage Drivers | OverlayFS, layer graph, CoW, image vs container layers, layer sharing, garbage collection | ~350 lines |
| 35 | `35-docker-networking.md` | Docker Networking | CNM, bridge/none/host/overlay/macvlan/ipvlan, iptables, DNS resolution, container-to-container | ~300 lines |
| 36 | `36-kaniko-vs-docker-builds.md` | Kaniko vs Docker Builds | Kaniko architecture (rootless, no daemon), comparison with Docker/BuildKit, trade-offs for CI/CD | ~300 lines |

## Navigation

Insert after the "Docker Product & Strategy" section in `mkdocs.yml`:

```yaml
  - Docker:
    - articles/30-docker-architecture.md
    - articles/31-build-context.md
    - articles/32-buildkit-internals.md
    - articles/33-how-docker-builds-images.md
    - articles/34-image-layers-storage-drivers.md
    - articles/35-docker-networking.md
    - articles/36-kaniko-vs-docker-builds.md
```

## Writing Conventions

- Target lengths as specified above. BuildKit Internals and How Docker Builds Images are the two deepest dives (~500 lines each).
- Interview-prep tone: thorough but accessible, explain "why" not just "what"
- Two-way cross-referencing: when new articles reference concepts from existing articles, link to them. And when existing articles mention Docker fundamentals now covered by new articles, update them with links.

## Cross-Reference Updates (Existing → New)

These existing articles mention Docker concepts that new articles cover. Add hyperlinks:

| Existing Article | Concept Mentioned | Link To |
|---|---|---|
| `01-slsa-framework.md` | BuildKit SLSA L3 compliance | `32-buildkit-internals.md` |
| `07-notary-docker-content-trust.md` | Image signing flow | `33-how-docker-builds-images.md` (manifest section) |
| `08-distroless-images.md` | Image layers, Dockerfile examples | `34-image-layers-storage-drivers.md` |
| `09-image-minimization.md` | Layer minimization strategies | `34-image-layers-storage-drivers.md` |
| `10-non-root-execution.md` | Container runtime, user namespaces | `30-docker-architecture.md` |
| `11-linux-capabilities.md` | Container runtime | `30-docker-architecture.md` |
| `12-seccomp.md` | Container runtime | `30-docker-architecture.md` |
| `13-apparmor-selinux.md` | Container runtime | `30-docker-architecture.md` |
| `14-readonly-filesystem.md` | Container filesystem layers | `34-image-layers-storage-drivers.md` |
| `15-multi-arch-security.md` | Image manifests, OCI spec | `33-how-docker-builds-images.md` |
| `20-scanner-internals.md` | Image layer analysis | `34-image-layers-storage-drivers.md` |
| `25-docker-scout.md` | BuildKit, Docker builds | `32-buildkit-internals.md`, `33-how-docker-builds-images.md` |
| `26-docker-hardened-images.md` | BuildKit SLSA L3 pipeline | `32-buildkit-internals.md`, `33-how-docker-builds-images.md`, `30-docker-architecture.md` |
| `27-docker-content-trust.md` | Image signing, manifests | `33-how-docker-builds-images.md` |
| `28-docker-supply-chain-platform.md` | Docker ecosystem, Build Cloud | `30-docker-architecture.md`, `32-buildkit-internals.md` |

## Cross-Reference Updates (New → Existing)

Each new article should link back to relevant existing articles (partial list):

| New Article | Link To Existing |
|---|---|
| `30-docker-architecture.md` | `10-non-root-execution.md` (user namespaces), `11-linux-capabilities.md`, `12-seccomp.md`, `13-apparmor-selinux.md`, `26-docker-hardened-images.md` |
| `31-build-context.md` | (few existing links — mostly new topic) |
| `32-buildkit-internals.md` | `26-docker-hardened-images.md` (SLSA L3 builds with BuildKit), `33-how-docker-builds-images.md` |
| `33-how-docker-builds-images.md` | `27-docker-content-trust.md` (image signing), `15-multi-arch-security.md` (multi-arch manifests), `32-buildkit-internals.md` (LLB/caching), `34-image-layers-storage-drivers.md` |
| `34-image-layers-storage-drivers.md` | `08-distroless-images.md`, `09-image-minimization.md`, `14-readonly-filesystem.md` |
| `35-docker-networking.md` | (few existing links — mostly new topic) |
| `36-kaniko-vs-docker-builds.md` | `30-docker-architecture.md` (why no daemon matters) |

## Acceptance Criteria

- `mkdocs build --strict` passes with no warnings
- All 7 articles render correctly with expected headings
- Internal cross-references use relative links (`../articles/nn-topic.md`)
- All 15 existing articles updated with appropriate links
