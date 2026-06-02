# Docker Section Articles Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a new "Docker" section of 7 articles to the interview-prep MkDocs site, with two-way cross-references to existing articles.

**Architecture:** 7 new markdown files under `docs/articles/`, plus updates to 15 existing articles to add cross-reference links. Modify `mkdocs.yml` nav. No code changes.

**Tech Stack:** MkDocs, Markdown

---

### Task 1: Create `docs/articles/30-docker-architecture.md`

**Files:**
- Create: `docs/articles/30-docker-architecture.md`

- [ ] **Write the article (~400 lines)**

Title: `# Docker Architecture`

Content covering:
- **Client-server model**: `docker` CLI communicates with dockerd via REST API on `/var/run/docker.sock` (Unix socket) — also available over TCP (TLS-secured)
- **dockerd**: long-running daemon process, responsible for image management, container lifecycle, volumes, networking. Calls into containerd for container operations.
- **containerd**: industry-standard container runtime (graduated to CNCF). Manages image pull/storage, container lifecycle (create/start/stop/delete), and provides gRPC API. Uses containerd-shim per container.
- **containerd-shim**: per-container process that keeps the container's STDIN/STDOUT open even if the daemon restarts. Acts as bridge between containerd and the OCI runtime.
- **runc**: OCI-compliant low-level runtime. Creates the container from config.json + rootfs. Uses Linux kernel features: namespaces (pid, net, mnt, user, uts, ipc), cgroups (v1/v2), seccomp, capabilities, SELinux/AppArmor.
- **OCI Runtime Spec**: config.json structure (process, root, mounts, linux.namespaces, linux.devices, linux.resources, linux.seccomp, linux.capabilities, linux.maskedPaths, linux.readonlyPaths)
- **OCI Image Spec**: manifest (json, media type, config reference, layer list), config (architecture, OS, rootfs, history, exposedPorts, env, entrypoint, cmd, volumes, workingDir, labels, user), layer tarballs
- **Docker vs containerd vs CRI**: containerd implements CRI (Container Runtime Interface) for Kubernetes via `cri` plugin. Docker sits above containerd. CRI-O is an alternative CRI-compliant runtime.
- **Docker in rootless mode**: dockerd-rootless.sh, user namespaces, fuse-overlayfs, slirp4netns
- **Cross-references**: link to `10-non-root-execution.md` (user namespaces), `11-linux-capabilities.md`, `12-seccomp.md`, `13-apparmor-selinux.md`, `26-docker-hardened-images.md`

~400 lines, H2 sections, code blocks (docker ps, ps auxf, ctr commands, runc spec examples, manifest JSON).

---

### Task 2: Create `docs/articles/31-build-context.md`

**Files:**
- Create: `docs/articles/31-build-context.md`

- [ ] **Write the article (~250 lines)**

Title: `# Build Context`

Content covering:
- **What is the build context**: all files and directories sent to Docker daemon/BuildKit when running `docker build`
- **Default context**: `.` (current directory). `docker build -f docker/Dockerfile .` still sends everything in `.` not just `docker/`
- **`.dockerignore` syntax**: `*`, `**/`, `!` negation, `!` cannot override a parent ignore (must match parent), `.dockerignore` is relative to build context root
- **Impact on build performance**: large context = long `Sending build context to Docker daemon` phase. BuildKit shows this as progress bars.
- **Context as tarball**: Docker client tars the context, sends via HTTP to daemon API
- **`.dockerignore` as security boundary**: don't send `.env`, `node_modules/`, `.git/`, `target/`, `__pycache__/`, `*.log`, `secrets/`
- **Remote contexts**: `docker build https://github.com/user/repo.git#branch:dir` — clones the repo as context. Also `docker build -` to stream context from stdin.
- **BuildKit's `local` source**: how BuildKit represents the context internally as a `local` source op in LLB
- **Practical `.dockerignore` examples**: Node.js, Go, Python, Java projects
- **Cross-references**: link to `32-buildkit-internals.md` (LLB), `33-how-docker-builds-images.md` (pipeline)

~250 lines, H2 sections, code blocks with Dockerfiles and .dockerignore files.

---

### Task 3: Create `docs/articles/32-buildkit-internals.md`

**Files:**
- Create: `docs/articles/32-buildkit-internals.md`

- [ ] **Write the article (~500 lines)**

Title: `# BuildKit Internals`

Content covering:
- **History and motivation**: why BuildKit replaced the legacy builder. Problems: no concurrent stage execution, poor caching, no cache mounts, no secrets, no SSH.
- **Architecture overview**: BuildKit can run embedded in dockerd, as a standalone daemon (`buildkitd`), or as a contained process. Components: frontend, solver, worker, exporter.
- **LLB (Low-Level Build) definition**: protobuf-based DAG. Ops: `SourceOp` (fetch base image, local directory, git repo), `ExecOp` (run a command), `FileOp` (copy, mkdir, rm), `BuildOp` (nested LLB). Each op has inputs, outputs, metadata.
- **LLB example**: show what a simple Dockerfile translates to in LLB. Dockerfile:
  ```dockerfile
  FROM alpine:3.19
  RUN apk add curl
  COPY app.sh /app.sh
  CMD ["/app.sh"]
  ```
  Produces: SourceOp(alpine:3.19) → ExecOp(apk add curl) → CopyOp(app.sh → /app.sh) → ExecOp(CMD)
- **Frontends**: `dockerfile.v0` and `dockerfile.v1`. How Dockerfile instructions map to LLB ops. Each `RUN` → `ExecOp`, each `COPY`/`ADD` → `FileOp.Copy`, each `FROM` → `SourceOp`. Gateways allow custom frontends (e.g., `sonatype/ray`).
- **Solver**: core of BuildKit. Takes LLB DAG, resolves dependencies, determines execution order. Uses content-addressed caching (each op output is identified by a content hash). Parallel execution: ops without dependencies execute concurrently (e.g., multi-stage builds with independent `FROM` bases).
- **Caching algorithm**: each op's cache key = hash(function + inputs + metadata). On cache hit, op is skipped (output loaded from cache). Cache invalidation: any change to Dockerfile, base image, build context, or env vars busts the cache for affected ops.
- **Cache mounts** (`RUN --mount=type=cache`): persistent directories shared across builds. Common targets: `/var/cache/apt`, `/root/.cache/pip`, `/go/pkg/mod`, `/root/.m2`. Cache lifetime: BuildKit uses TTL-based garbage collection.
- **Secrets** (`RUN --mount=type=secret`): mounted as tmpfs (never stored in image layers). Used for private repo access, npm tokens, etc. BuildKit's `--secret` flag passes secret data via pipe (not env var).
- **SSH** (`RUN --mount=type=ssh`): forwards SSH agent socket into build. Used for cloning private repos during build.
- **BuildKit cache export**: cache can be exported to a registry (`--cache-to`/`--cache-from`) for CI reuse. Modes: `inline` (in image), `registry` (separate cache manifest), `gha` (GitHub Actions cache).
- **Cross-references**: link to `26-docker-hardened-images.md` (SLSA L3/attestations with BuildKit), `33-how-docker-builds-images.md` (pipeline integration)

~500 lines, H2 sections, code blocks with LLB JSON examples, buildctl commands, BuildKit daemon config, Dockerfile examples.

---

### Task 4: Create `docs/articles/33-how-docker-builds-images.md`

**Files:**
- Create: `docs/articles/33-how-docker-builds-images.md`

- [ ] **Write the article (~500 lines)**

Title: `# How Docker Builds Images`

Content covering the full end-to-end pipeline:

**Stage 1 — Dockerfile Parsing**:
- Dockerfile lexer/parser (pkg/dockerfile/parser in moby/buildkit). Tokenizes instructions: `FROM`, `RUN`, `CMD`, `LABEL`, `MAINTAINER`, `EXPOSE`, `ENV`, `ADD`, `COPY`, `ENTRYPOINT`, `VOLUME`, `USER`, `WORKDIR`, `ARG`, `ONBUILD`, `STOPSIGNAL`, `HEALTHCHECK`, `SHELL`.
- Parses heredocs (BuildKit supports heredoc syntax in RUN). Produces AST: `*parser.Node` with `Value`, `Next`, `Children` fields.
- Shows example AST output for a simple Dockerfile (simplified JSON representation).

**Stage 2 — Frontend Translation (Dockerfile → LLB)**:
- `dockerfile.v1` frontend (reimplemented in Go, replaces older cabal-based `dockerfile.v0`).
- Translation rules: `FROM` → `SourceOp` (pull base image from registry or use local). `RUN` → `ExecOp` (run command in intermediate container, capture diff). `COPY` → `FileOp.Copy` (copy from context or previous stage). `ENV`/`WORKDIR`/`USER` → metadata on ExecOp (not separate layers).
- Multi-stage builds: each `FROM` starts a new sub-graph. Final stage defined by last `FROM` or `--target` flag. Unused stages are skipped (BuildKit prunes unreachable ops).

**Stage 3 — LLB Graph Resolution**:
- Solver builds the DAG, resolves cache keys for each op. Content-hash includes: command text, environment variables, working directory, user, base image digest, build args.
- Cache hit → skip op entirely (use cached result). Cache miss → schedule op for execution.
- Independent ops run in parallel: e.g., `FROM golang:1.22 AS builder` and `FROM alpine:3.19 AS runtime` pull in parallel if they have no dependency.

**Stage 4 — Solver Execution**:
- For `ExecOp`: BuildKit creates a temporary container (via runc/containerd), runs the command, captures the filesystem diff. Uses snapshotters (overlayfs) to track changes efficiently.
- For `FileOp.Copy`: BuildKit copies files from one snapshot to another (optimized for handling large context tarballs).
- Execution traces: `BUILDKIT_PROGRESS=plain` shows each op's status. Example output showing parallel downloads.

**Stage 5 — Layer Export**:
- Each `ExecOp` produces a layer: tar archive of filesystem changes (created by differ — walks the diff between before/after snapshots using overlayfs whiteout files).
- Whiteout files: `.wh.` prefix for deleted files, `.wh..wh..opq` for opaque directory (all children deleted).
- Layers are content-addressed: digest = sha256 of layer tar. Reusable from cache.
- `FROM` layers are not re-exported — they reference the base image's existing layers in the manifest.

**Stage 6 — Image Manifest Assembly**:
- `config.json`: architecture, OS, rootfs.diff_ids (list of layer digests), history (list of commands), exposedPorts, env, entrypoint, cmd, volumes, workingDir, labels. Diff_ids are the uncompresssed layer digests.
- `manifest.json`: schemaVersion, mediaType, config (reference to config.json digest), layers (list of layer blob digests). Layer digests are the compressed tar digests.
- How `docker history --no-trunc` shows the config's history entries.

**Stage 7 — Push**:
- Layers pushed in parallel to registry (concurrent goroutines with retry logic). Each blob uploaded via POST/PUT.
- Manifest pushed last (atomic update). Registry stores manifest by tag reference.
- BuildKit's `--push` flag handles this automatically. Output types: `type=image`, `type=docker`, `type=oci`, `type=local`, `type=tar`.

**Cross-references**: link to `27-docker-content-trust.md` (image signing/Notary), `15-multi-arch-security.md` (multi-arch manifests), `32-buildkit-internals.md` (LLB/caching deep dive), `34-image-layers-storage-drivers.md` (layer storage), `26-docker-hardened-images.md` (attestations), `31-build-context.md` (context handling)

~500 lines, H2 sections, code blocks with Dockerfile AST, LLB JSON, manifest JSON, config JSON, shell output.

---

### Task 5: Create `docs/articles/34-image-layers-storage-drivers.md`

**Files:**
- Create: `docs/articles/34-image-layers-storage-drivers.md`

- [ ] **Write the article (~350 lines)**

Title: `# Image Layers & Storage Drivers`

Content covering:
- **Layer concept**: each Dockerfile instruction creates a layer (except `ENV`, `WORKDIR`, `USER`, `VOLUME`, `EXPOSE`, `CMD`, `ENTRYPOINT`, `LABEL`, `SHELL`, `MAINTAINER`, `ARG`). Layer = tar of filesystem diff. Shows `docker history` output.
- **Layer graph**: content-addressable storage. Each layer references its parent. Chain of layers → image. `docker image inspect` shows `RootFS.Layers` (list of layer digests).
- **Layer sharing**: images sharing base layers (e.g., Ubuntu-based images) share the same layer blobs on disk. Only unique layers consume additional space. `docker system df` shows shared/unique layer sizes.
- **OverlayFS theory**: lowerdir (multiple read-only layers), upperdir (writable layer), merged (union view). Reads: check upper first, fall through to lower. Writes: copy-up from lower to upper, then modify (CoW). Deletes: create whiteout in upper.
- **OverlayFS in Docker**: `lowerdir` = image layers (read-only, stacked), `upperdir` = container's writable layer (thin, ~0 bytes), `merged` = what the container sees. `workdir` = scratch for atomic operations. `cat /proc/self/mountinfo` shows the overlay mount.
- **Copy-on-write**: reading from upper shadows lower. Writing to a lower-layer file triggers copy-up (read from lower, write to upper), then modify. First write to a file is slower due to copy-up.
- **Container layer lifecycle**: created on `docker run`, destroyed on `docker rm` (unless the container is committed). Thin writable layer limits how much data a container can write (use volumes for large writes).
- **Storage drivers**: overlay2 (default since Docker 18.09+), fuse-overlayfs (rootless mode). Older: aufs, devicemapper, overlay, vfs. Why overlay2 wins: inode-efficient, page cache sharing (kernel shares cached pages across layers), performance.
- **Garbage collection**: `docker image prune`, `docker builder prune`, `docker system prune`. BuildKit GC: LRU-based, configurable policies (`keepStorage`, `maxUsedPercent`, `minCacheDuration`).
- **`docker save`/`docker load`**: export/import images as tarballs (preserves layer structure).
- **Cross-references**: link to `08-distroless-images.md` (base image size), `09-image-minimization.md` (layer reduction techniques), `14-readonly-filesystem.md` (read-only rootfs), `20-scanner-internals.md` (layer analysis during scanning)

~350 lines, H2 sections, code blocks with overlayfs mounts, docker history, docker inspect, layer walk diagrams.

---

### Task 6: Create `docs/articles/35-docker-networking.md`

**Files:**
- Create: `docs/articles/35-docker-networking.md`

- [ ] **Write the article (~300 lines)**

Title: `# Docker Networking`

Content covering:
- **CNM (Container Network Model)**: three building blocks — Sandbox (network namespace, `netns`), Endpoint (virtual ethernet — veth pair), Network (bridge — software switch). Docker's libnetwork implements CNM.
- **`--network bridge` (default)**: `docker0` bridge created by dockerd. Containers get veth pairs: one end in container netns (eth0), one plugged into docker0. NAT via iptables MASQUERADE (Source NAT). `-p 8080:80` adds DNAT rule (`PREROUTING` chain). Show `iptables -t nat -L -n`.
- **User-defined bridge**: created with `docker network create mynet`. Better isolation (only containers on same bridge can communicate). Built-in DNS resolution by container name (embedded DNS at 127.0.0.11).
- **`--network host`**: container shares host network namespace. No veth pair, no netns, no NAT. Performance benefit (no bridge hop) but zero isolation. Process management conflicts (both container and host can bind same port). Security risk.
- **`--network none`**: loopback only (lo interface). No external connectivity. Used for security testing or when only Unix sockets are needed.
- **`--network overlay`**: VXLAN encapsulation (UDP 4789). Used by Docker Swarm. Each overlay network gets its own VNI. Spoof protection via VXLAN headers. IPsec encryption optional.
- **`--network macvlan`/`ipvlan`**: containers get real MAC/IP on physical network. No NAT, bypasses docker0. macvlan: each container has unique MAC (switch port limits). ipvlan L2/L3 modes: containers share parent MAC (avoids MAC flooding).
- **DNS resolution**: embedded DNS resolver at 127.0.0.11 (inside container). For user-defined networks, resolves container names to IPs. Falls through to host DNS for external resolution. Custom DNS via `--dns`.
- **Container-to-container communication**: on same bridge — direct L2. Across bridges — need routing. Across hosts — overlay or macvlan. iptables FORWARD chain controls inter-container traffic (DOCKER-USER chain for custom rules).
- **Network security**: `--network host` bypasses isolation. User-defined bridge provides DNS-based service discovery (no `--link` needed). Network policies (Docker EE/UCP, now Mirantis). `iptables -D` is not persistent.
- **Cross-references**: (few existing links — mostly new terrain in this project)

~300 lines, H2 sections, code blocks with docker network commands, iptables output, netns inspection.

---

### Task 7: Create `docs/articles/36-kaniko-vs-docker-builds.md`

**Files:**
- Create: `docs/articles/36-kaniko-vs-docker-builds.md`

- [ ] **Write the article (~300 lines)**

Title: `# Kaniko vs Docker Builds`

Content covering:
- **What is Kaniko**: Google's open-source tool for building container images in Kubernetes without Docker daemon or privileged access. Part of Google's container tools ecosystem.
- **Why Kaniko exists**: Docker daemon requires root/socket access. In Kubernetes, mounting `/var/run/docker.sock` is insecure (gives pod node-level access). Kaniko runs without any daemon.
- **Kaniko architecture**: runs as a container (usually `gcr.io/kaniko-project/executor`). Extracts base image to rootfs. Executes each Dockerfile command in userspace using: `chroot` to the target rootfs, `ptrace` to snapshot filesystem changes after each command. Builds new layers from the filesystem diff.
- **Detailed pipeline**: 
  1. Parse Dockerfile
  2. Pull base image (to `/kaniko/`)
  3. For each instruction: apply chroot, run command, snapshot filesystem (via ptrace + tar), push layer to registry (or cache)
  4. After all instructions, push final manifest
- **Comparison table**: 

| Feature | Docker BuildKit | Kaniko |
|---------|---------------|--------|
| Architecture | Daemon-based (containerd) | Standalone binary (userspace) |
| Root requirement | Needs root/privileged | Can run as non-root |
| Layer caching | Content-hash, shared across builds | Only remote registry caching (--cache=true) |
| Cache mounts | Full support (--mount=type=cache) | Not supported |
| Secrets | --secret, --ssh, --mount=type=secret | Via Kubernetes secrets (mounted files) |
| Multi-stage | Full support + parallel stages | Full support (sequential) |
| Speed | Fast (parallel, cached) | Slower (sequential, no cache mounts) |
| Dockerfile compat | Full + extended (heredocs, --mount) | High (limited --mount support) |
| Use case | Dev machines, CI with Docker socket | Kubernetes CI (no Docker socket) |
| Debugging | Rich (buildctl, buildx inspect) | Limited (--verbosity debug) |
| Push method | Direct (parallel blob uploads) | Direct (sequential by default) |

- **When to use which**: BuildKit for speed + feature set, Kaniko for secure K8s CI (GitLab CI, Tekton, Argo Workflows). Also: BuildKit can run rootless with `buildkitd` for a middle ground.
- **Alternatives**: Buildah (part of Podman ecosystem, uses overlayfs in userspace), img (BuildKit wrapper), makisu (Uber's in-cluster builder, uses overlayfs)
- **Cross-references**: link to `30-docker-architecture.md` (why no daemon matters for security), `32-buildkit-internals.md` (BuildKit features), `33-how-docker-builds-images.md` (how Docker builds differ)

~300 lines, H2 sections, code blocks with Kaniko commands, Kubernetes pod specs, comparison tables.

---

### Task 8: Update `mkdocs.yml` navigation

**Files:**
- Modify: `mkdocs.yml`

- [ ] **Add Docker section to nav**

Insert after the `Docker Product & Strategy:` nav block (after line 48, before `extra_css:` on line 49):

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

---

### Task 9: Update cross-references in existing articles (New → Existing links)

**Files:**
- Modify: existing articles as needed

- [ ] **Verify new articles link to existing articles**

The new articles already have cross-reference links embedded (specified in Tasks 1-7). Verify each new article's links are correct relative paths (`../articles/nn-topic.md`).

---

### Task 10: Update cross-references in existing articles (Existing → New links)

**Files:**
- Modify: `docs/articles/01-slsa-framework.md`
- Modify: `docs/articles/07-notary-docker-content-trust.md`
- Modify: `docs/articles/08-distroless-images.md`
- Modify: `docs/articles/09-image-minimization.md`
- Modify: `docs/articles/10-non-root-execution.md`
- Modify: `docs/articles/11-linux-capabilities.md`
- Modify: `docs/articles/12-seccomp.md`
- Modify: `docs/articles/13-apparmor-selinux.md`
- Modify: `docs/articles/14-readonly-filesystem.md`
- Modify: `docs/articles/15-multi-arch-security.md`
- Modify: `docs/articles/20-scanner-internals.md`
- Modify: `docs/articles/25-docker-scout.md`
- Modify: `docs/articles/26-docker-hardened-images.md`
- Modify: `docs/articles/27-docker-content-trust.md`
- Modify: `docs/articles/28-docker-supply-chain-platform.md`

- [ ] **Update `01-slsa-framework.md`**: Where BuildKit SLSA L3 is mentioned, add link to `32-buildkit-internals.md`.

- [ ] **Update `07-notary-docker-content-trust.md`**: Where image flow/manifest is discussed, add link to `33-how-docker-builds-images.md`.

- [ ] **Update `08-distroless-images.md`**: Where image layers are discussed, add link to `34-image-layers-storage-drivers.md`.

- [ ] **Update `09-image-minimization.md`**: Where layer minimization is discussed, add link to `34-image-layers-storage-drivers.md`.

- [ ] **Update `10-non-root-execution.md`**: Where container runtime/user namespaces are discussed, add link to `30-docker-architecture.md`.

- [ ] **Update `11-linux-capabilities.md`**: Where container runtime context is discussed, add link to `30-docker-architecture.md`.

- [ ] **Update `12-seccomp.md`**: Where container runtime/seccomp profile loading is discussed, add link to `30-docker-architecture.md`.

- [ ] **Update `13-apparmor-selinux.md`**: Where container runtime is discussed, add link to `30-docker-architecture.md`.

- [ ] **Update `14-readonly-filesystem.md`**: Where container filesystem layers are discussed, add link to `34-image-layers-storage-drivers.md`.

- [ ] **Update `15-multi-arch-security.md`**: Where image manifests/OCI spec is discussed, add link to `33-how-docker-builds-images.md`.

- [ ] **Update `20-scanner-internals.md`**: Where image layer analysis is discussed, add link to `34-image-layers-storage-drivers.md`.

- [ ] **Update `25-docker-scout.md`**: Where BuildKit/Docker builds are discussed, add links to `32-buildkit-internals.md` and `33-how-docker-builds-images.md`.

- [ ] **Update `26-docker-hardened-images.md`**: Where BuildKit SLSA L3 pipeline is discussed, add links to `30-docker-architecture.md`, `32-buildkit-internals.md`, and `33-how-docker-builds-images.md`.

- [ ] **Update `27-docker-content-trust.md`**: Where image signing/manifests are discussed, add link to `33-how-docker-builds-images.md`.

- [ ] **Update `28-docker-supply-chain-platform.md`**: Where Docker ecosystem/Build Cloud is discussed, add links to `30-docker-architecture.md` and `32-buildkit-internals.md`.

---

### Task 11: Build and verify

**Files:**
- None

- [ ] **Run `mkdocs build --strict`**

```bash
source .venv/bin/activate && mkdocs build --strict
```

Expected output: no errors or warnings, build succeeds.

- [ ] **Verify navigation renders correctly**

Open the built site or check `site/index.html` for the new Docker section with all 7 articles listed.

---

### Self-Review

**Spec coverage:**
- 7 new articles cover all specified topics with target line counts
- Cross-reference mapping covers all 15 existing articles that mention relevant Docker concepts
- Two-way linking: new articles link to existing, existing articles link to new

**Placeholder scan:** No TODOs, TBDs, or incomplete sections. Every step has complete content.

**Consistency check:** Article numbering (30-36) matches file names. Nav entries match file names. Cross-reference targets match real file paths.
