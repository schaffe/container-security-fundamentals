---
title: "BuildKit Internals"
section: "Docker"
order: 32
---

# BuildKit Internals

## History and Motivation

Before BuildKit, Docker used a **legacy builder** — a monolithic implementation inside `dockerd`
that processed Dockerfiles sequentially, one instruction at a time. Each `RUN`, `COPY`, and `ADD`
instruction created a container, executed a command, committed the filesystem, and moved to the next
line. The approach worked, but it had fundamental limitations that became painful as container builds
grew more complex.

### Problems with the Legacy Builder

**No concurrent stage execution.** Multi-stage builds (`FROM golang:1.21 AS builder ... FROM alpine`)
ran stages sequentially even when stages had no dependency on each other. The builder never analysed
the DAG — it just ran instructions top-to-bottom.

**Poor caching.** Cache invalidation was coarse: any change to the Dockerfile, build context, or base
image busted the entire cache for that line and everything after it. There was no content-addressed
cache — the builder compared command strings verbatim, so whitespace changes triggered rebuilds.

**No cache mounts.** If a build downloaded packages (`apt-get install`, `pip install`), those
packages were re-downloaded every time the cache missed — even if only an unrelated `COPY` changed.
There was no mechanism to persist `/var/cache/apt` or `/root/.cache/pip` across builds.

**No secrets support.** Passing credentials to a build meant either baking them into an intermediate
layer with `ENV` / `ARG` (leaking them into the image history) or including them in the build
context (risking inclusion in production images).

**No SSH agent forwarding.** Cloning private repositories during a build required embedding SSH keys
in the context or using `--build-arg` with the key material — both terrible security practices.

**Single-architecture, single output.** The legacy builder built one platform per invocation.
Producing multi-arch images meant running `docker build` on each platform and stitching manifests
manually.

### Enter BuildKit

BuildKit was introduced as a technical preview in Docker 18.06, became stable in Docker 18.09, and
replaced the legacy builder as the default in Docker 23.0 (via `docker buildx`). The `DOCKER_BUILDKIT=1`
environment variable enabled it on older versions.

It was designed from the ground up around a DAG execution model, content-addressed caching, and a
pluggable architecture:

```
Legacy builder:   sequential, monolithic, string-address caching
BuildKit:         DAG-based, modular, content-address caching
```

BuildKit's design borrows ideas from Bazel's remote execution API and Nix's store model — build
steps are pure(ish) functions that can be cached, parallelised, and distributed.

For the architectural context of where BuildKit fits in the Docker stack, see
[Docker Architecture](docker-architecture.md).

---

## Architecture Overview

BuildKit is not a single binary or daemon — it is a collection of components that can be composed in
different configurations:

```
+-----------+
| Frontend  |  (e.g., dockerfile.v0, dockerfile.v1, custom gateway)
+-----------+       |
          v
+-----------+       +-----------+
| Solver    | ----> |   Cache   |  (content-addressed, pluggable backends)
+-----------+       +-----------+
    |                       |
    v                       v
+-----------+       +-----------+
|  Worker   |       | Exporter  |  (image, local tarball, OCI layout, containerd store)
+-----------+       +-----------+
    |
    v
+-----------+       +-----------+
|  runc /   |       |   LLB     |  (internal IR used by all components)
| containerd|       |  (DAG)    |
+-----------+       +-----------+
```

### Deployment Modes

BuildKit can run in three modes:

**Embedded in dockerd.** Since Docker 23.0, `dockerd` embeds BuildKit as a library. When you run
`docker build`, BuildKit runs as a contained set of goroutines inside the daemon process. No
separate daemon needed.

**Standalone daemon (`buildkitd`).** A dedicated process listening on a Unix or TCP socket. This is
how `docker buildx` with a remote builder works. The BuildKit daemon can run on a separate machine
or in a Kubernetes pod.

```bash
buildkitd --config /etc/buildkitd.toml
```

**Client library.** BuildKit's Go packages can be imported directly to construct and execute LLB
graphs programmatically. This is how tools like `earthly` and `dagger` integrate with BuildKit.

### Components

**Frontend** — Converts high-level build instructions (Dockerfile, custom DSL) into LLB. The
frontend runs inside a container (the "frontend image") and produces LLB protobuf on stdout. The
solver receives this LLB and executes it.

**Solver** — The core engine. Receives an LLB graph, resolves dependencies, checks the cache,
parallelises work, and dispatches operations to workers.

**Worker** — Executes individual LLB operations. Two built-in workers:

- `runc` worker: Uses [`runc`](docker-architecture.md#architecture) via containerd to execute `ExecOp` instructions in containers.
- `containerd` worker: Uses containerd directly for both exec and snapshot management.
- `oci` worker (experimental): Uses `runtime-tools` directly.

**Exporter** — Converts the solver's output into a usable artifact. Common exporters:
`image` (push to registry), `local` (write to filesystem), `tar` (write tarball), `oci` (OCI image
layout), `containerd` (store in containerd's content store), `docker` (Docker image format).

**Cache backend** — Stores and retrieves cache blobs. Supported backends: local filesystem,
registry, GitHub Actions cache, S3, Azure Blob Storage.

---

## LLB (Low-Level Build) Definition

LLB is the intermediate representation (IR) that everything in BuildKit compiles to. It is defined
as a protobuf message and represents a **directed acyclic graph (DAG)** of operations.

### Protobuf Definition

The core LLB types live in `github.com/moby/buildkit/solver/pb`:

```protobuf
message Op {
  repeated Input inputs = 1;
  oneof op {
    SourceOp source = 2;
    ExecOp exec = 3;
    FileOp file = 4;
    BuildOp build = 5;
  }
  // Metadata attached to every op
  OpMetadata metadata = 6;
}

message Input {
  string digest = 1;   // content hash of the source op
  int64 index = 2;     // output index (0 = default)
}
```

### Op Types

**SourceOp** — Fetches external data. Three variants:

| Source Type | Purpose | Example |
|-------------|---------|---------|
| `containerimage` | Pull a container image | `FROM alpine:3.19` |
| `local` | Read files from build context | `COPY . /app` |
| `git` | Clone a git repository | `FROM git@github.com/...` |

An `http` source also exists for fetching URLs directly.

SourceOps are leaf nodes — they have no inputs.

**ExecOp** — Runs a command in a container. This is the workhorse: every `RUN` instruction becomes
an ExecOp. It specifies:

- Mounts (rootfs, cache mounts, tmpfs, secret mounts, ssh mounts)
- Arguments, environment variables, working directory
- Network mode, security mode
- User, group

```go
// Conceptual Go representation
execOp := llb.Exec(
  llb.Args([]string{"/bin/sh", "-c", "apk add curl"}),
  llb.Mount("rootfs", baseImage, llb.Readonly),   // the FROM image
  llb.Mount("/tmp", llb.Scratch, llb.Tmpfs),       // ephemeral tmpfs
)
```

**FileOp** — Filesystem operations without running a container. Sub-ops:

| FileAction | Purpose |
|------------|---------|
| `Copy` | Copy files between inputs (`COPY`, `ADD`) |
| `Mkdir` | Create directories |
| `Mkfile` | Create files with content |
| `Rm` | Remove files or directories |

FileOps are critical for efficiency: they avoid the overhead of creating a container just to copy
files.

**BuildOp** — Nested LLB execution. Used by frontend gateways and `docker buildx` for recursive
builds. A BuildOp takes an LLB definition and executes it as a sub-graph, producing outputs that
feed into the parent graph.

### Metadata

Every Op carries `OpMetadata`:

```go
type OpMetadata struct {
  Description map[string]string  // human-readable labels
  ExportCache  *bool              // whether to cache this op's output
}
```

The solver uses metadata for cache control and progress reporting.

---

## LLB Example

Consider this Dockerfile:

```dockerfile
FROM alpine:3.19
RUN apk add curl
COPY app.sh /app.sh
CMD ["/app.sh"]
```

BuildKit's frontend (dockerfile.v0/v1) converts this into an LLB graph. Here is the conceptual
structure:

```
SourceOp(containerimage:alpine:3.19)
    |
    v
ExecOp(run: "apk add curl")
  mount: rootfs = SourceOp(containerimage:alpine:3.19)
  mount: /tmp = tmpfs
    |
    v
FileOp(Copy)
  input0: SourceOp(local:context)   -- build context
  input1: output of ExecOp(apk add) -- the working filesystem
  src: app.sh
  dest: /app.sh
    |
    v
ExecOp(config: CMD)
  mount: rootfs = output of FileOp(Copy)
  args: ["/app.sh"]
  -- this ExecOp only records the config, no actual runtime execution
```

### Visualising LLB

BuildKit includes a tool to dump the LLB graph:

```dockerfile
# syntax=docker/dockerfile:1
FROM alpine:3.19 AS base
RUN apk add curl
COPY app.sh /app.sh
```

```bash
# Build with LLB dump
docker build --debug --no-cache .
```

Or programmatically, using BuildKit's Go SDK:

```go
package main

import (
  "github.com/moby/buildkit/client/llb"
  "github.com/moby/buildkit/frontend/dockerfile/dockerfile2llb"
)

func buildLLB() (*llb.State, error) {
  // SourceOp: container image
  base := llb.Image("alpine:3.19")

  // ExecOp: run command
  run := base.Run(
    llb.Args([]string{"/bin/sh", "-c", "apk add curl"}),
    llb.AddMount("/tmp", llb.Scratch, llb.Tmpfs),
  )

  // FileOp: copy file from context
  src := llb.Local("context")
  copy := run.File(llb.Copy(src, "app.sh", "/app.sh", nil))

  return copy, nil
}
```

The output of each LLB op is identified by its **content hash** (digest of the op definition +
inputs). This is the foundation of BuildKit's caching.

### How Instructions Map

| Dockerfile Instruction | LLB Op |
|------------------------|--------|
| `FROM image AS stage` | `SourceOp(containerimage)` |
| `RUN command` | `ExecOp` with rootfs mount |
| `COPY src dst` | `FileOp.Copy` (or `ExecOp` with `--chmod`) |
| `ADD src dst` | `FileOp.Copy` (with auto-extract for tarballs/URLs) |
| `WORKDIR /path` | `FileOp.Mkdir` + metadata |
| `ENV K=V` | `ExecOp` metadata or merged into image config |
| `CMD ["exec"]` | Stored in image config, no LLB op |
| `EXPOSE port` | Stored in image config, no LLB op |
| `VOLUME /path` | Stored in image config, no LLB op |
| `LABEL K=V` | Stored in image config, no LLB op |

The frontend produces an `llb.State` that the solver traverses. See
[Build Context](build-context.md) for how the `local` source type interacts with the
build context.

---

## Frontends

A frontend is a container image that converts high-level build instructions into an LLB graph (a
`Definition` in protobuf). The frontend runs inside a BuildKit worker container, reads the build
input (Dockerfile or custom format), and outputs LLB to stdout.

### dockerfile.v0 and dockerfile.v1

The two built-in Dockerfile frontends:

**dockerfile.v0** — The original. Converts a Dockerfile to LLB. Syntax directive is limited:
`# syntax=docker/dockerfile:1`. Stable, well-tested.

**dockerfile.v1** — The current default. Adds support for `# syntax` parser directives, BuildKit-
specific RUN flags (`--mount`, `--network`, `--security`), and heredoc syntax. Enabled by:

```dockerfile
# syntax=docker/dockerfile:1
```

The frontend image is specified by the `# syntax` directive. Common images:

- `docker/dockerfile:1` — latest stable (v1)
- `docker/dockerfile:1.9` — pinned major.minor
- `docker/dockerfile:1.9.0` — pinned full version
- `docker/dockerfile:labs` — experimental features

```bash
docker build --no-cache \
  -f Dockerfile \
  --build-arg BUILDKIT_SYNTAX=docker/dockerfile:1.9 \
  .
```

### Gateway Frontends

BuildKit supports custom frontends through the **gateway API**. A gateway frontend is any container
image that implements the LLB gateway protocol — it receives an input (usually a Dockerfile) and
returns LLB.

Popular community gateways:

- **earthly/earthly** — Earthly's own build DSL compiles down to LLB through BuildKit
- **moby/buildkit:master** — Development builds with experimental features
- **tonistiigi/xx** — Cross-compilation helpers for multi-platform builds

```dockerfile
# syntax=earthly/earthly
FROM alpine:3.19
RUN apk add curl
```

The gateway architecture allows any build system to target BuildKit's solver without modifying
BuildKit itself.

---

## Solver

The solver is the heart of BuildKit. It takes an LLB `Definition` (a serialised DAG) and executes
it efficiently.

### Input Processing

1. **Deserialise** — Parse the LLB protobuf into an in-memory graph of `Op` nodes.
2. **Validate** — Check that the DAG has no cycles, all inputs reference existing ops, and all ops
   have required fields.
3. **Resolve** — Walk the graph bottom-up, computing cache keys for each op.
4. **Schedule** — Determine execution order. Ops with no uncompleted dependencies are eligible for
   immediate execution.

### Parallel Execution

The solver maintains a **frontier** of ops whose dependencies are satisfied. As each op completes,
it may unblock downstream ops, adding them to the frontier. This is classic DAG scheduling.

```
    SourceOp(nginx:1.25)      SourceOp(alpine:3.19)
            |                         |
            v                         v
        ExecOp(apt)              SourceOp(golang:1.21)
            |                         |
            +-----------+-------------+
                        |
                        v
                  ExecOp(COPY --from)
```

In this build, `SourceOp(nginx:1.25)` and `SourceOp(alpine:3.19)` run in parallel because they are
independent. Only the final `ExecOp(COPY --from)` must wait for both.

### Content-Addressed Operations

Each op's output is identified by a **content hash** — the digest of the op's definition + the
digests of all inputs. This is the same pattern Git uses: the hash of a node commits to the hashes
of its parents.

```
cacheKey(op) = sha256( op.type || op.payload || op.inputs[].digest || op.metadata )
```

This means if any input or parameter changes, the cache key changes — no ambiguity, no string
comparison edge cases.

---

## Caching Algorithm

### Cache Key Derivation

Every LLB operation produces a **cache key** and potentially a **content key**:

- **Cache key**: hash of the op definition + input digests. Determines whether the op is a cache
  hit or miss.
- **Content key**: hash of the op output (the actual filesystem / data after execution). Used for
  content-addressable lookups in the cache store.

```
Op: ExecOp(apk add curl)
Inputs: [SourceOp(alpine:3.19) cacheKey: abc123]
Metadata: args=["/bin/sh", "-c", "apk add curl"], env=[]

cacheKey = sha256("ExecOp" + "apk add curl" + "abc123" + "...")
```

### Cache Hit Flow

1. Solver computes `cacheKey` for the op.
2. Queries the cache backend: "Do you have a result for cache key `X`?"
3. On hit: Load the cached result (layer snapshots or data blobs) and skip execution.
4. On miss: Execute the op, store the result in the cache.

### Cache Invalidation Triggers

Any change to any of these invalidates the cache for the affected op and its transitive dependents:

- Dockerfile instruction text (e.g., `RUN apt-get install curl` → `RUN apt-get install curl jq`)
- Base image digest (a new `alpine:3.19` manifest changes the SourceOp cache key)
- Build context files (modified source code changes the `local` SourceOp digest)
- Environment variables (`--build-arg`)
- BuildKit version / frontend version
- Platform (`--platform linux/arm64` vs `linux/amd64`)
- Network mode (`--network host` vs default)

### Cache Sharing

Because cache keys are content-hashes, two builds using the same base image and same commands share
cache — even if they are different projects. This is why CI runners with persistent BuildKit daemons
see significant speedups after the first build.

---

## Cache Mounts

A cache mount persists a directory across builds without including it in the final image. It is
enabled by the `RUN --mount=type=cache` flag:

```dockerfile
# syntax=docker/dockerfile:1
FROM ubuntu:22.04
RUN --mount=type=cache,target=/var/cache/apt \
  apt-get update && apt-get install -y curl
```

### How It Works

1. BuildKit creates a persistent snapshot identified by the **cache mount ID** (derived from the
   mount target path by default, or a custom `id=`).
2. The directory is mounted as a writable overlay on top of the container's rootfs.
3. Changes written to the mount are saved after the RUN completes.
4. On the next build, the same cache snapshot is mounted — the previous downloads are available.

### Common Targets

| Ecosystem | Cache Target | Effect |
|-----------|-------------|--------|
| Debian/Ubuntu | `/var/cache/apt` | Avoid re-downloading `.deb` packages |
| Alpine | `/var/cache/apk` | Avoid re-downloading `.apk` packages |
| Python | `/root/.cache/pip` | Avoid re-downloading wheels |
| Go | `/go/pkg/mod` | Avoid re-downloading Go modules |
| Rust | `/usr/local/cargo/registry` | Avoid re-downloading crates |
| Node.js | `/root/.npm` | Avoid re-downloading npm packages |
| Java/Maven | `/root/.m2` | Avoid re-downloading Maven dependencies |
| Java/Gradle | `/root/.gradle` | Avoid re-downloading Gradle dependencies |
| Yarn | `/usr/local/share/.cache/yarn` | Avoid re-downloading yarn packages |
| ccache | `/root/.ccache` | Speed up C/C++ recompilation |

### Example: APT with Cache Mount

```dockerfile
# syntax=docker/dockerfile:1
FROM ubuntu:22.04 AS base

# caches apt packages across builds
RUN \
  --mount=type=cache,target=/var/cache/apt,sharing=locked \
  --mount=type=cache,target=/var/lib/apt/lists,sharing=locked \
  apt-get update && \
  apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    gnupg \
  && rm -rf /var/lib/apt/lists/*
```

The `sharing=locked` flag prevents concurrent builds from corrupting the cache.

### Cache Lifetimes

Cache mounts persist indefinitely by default, but BuildKit's garbage collector removes unused cache
after a configurable TTL:

```toml
# /etc/buildkitd.toml
[worker.oci]
  gc = true
  gc-keepduration = 86400  # keep unused cache for 24 hours
  gc-reserved = "10GB"     # keep at least 10 GB free
```

BuildKit also supports manual cache pruning:

```bash
docker builder prune --filter type=exec.cachemount
docker buildx prune --filter type=exec.cachemount  # for buildx builders
```

---

## Secrets

BuildKit's `RUN --mount=type=secret` mounts sensitive data as a tmpfs inside the build container.
The secret is never written to any layer and is discarded when the RUN instruction completes.

### Usage

```dockerfile
# syntax=docker/dockerfile:1
FROM node:20 AS build
RUN --mount=type=secret,id=npmrc \
  cp /run/secrets/npmrc ~/.npmrc && \
  npm ci --only=production
```

```bash
docker build --secret id=npmrc,src=.npmrc .
```

### How It Works

1. The `--secret` flag sends the secret data to BuildKit via a **pipe** (not an environment
   variable — `env` output will not leak it).
2. BuildKit stores the data in memory within the solver process.
3. When the `ExecOp` runs, the secret is mounted as a tmpfs at `/run/secrets/<id>` (or a custom
   `target=` path).
4. The tmpfs is visible only to that specific container process.
5. After the `ExecOp` completes, the tmpfs is unmounted and the memory is freed.

### Security Properties

- **Not in layers**: The secret never touches the snapshotter. It is a pure tmpfs mount.
- **Not in build history**: The secret value does not appear in `docker history`.
- **Not in build context**: The secret file is never included in the context tarball.
- **Not in daemon logs**: BuildKit does not log the secret contents.

### Common Use Cases

| Secret | Mount ID | Typical Source |
|--------|----------|----------------|
| npm token | `npmrc` | `~/.npmrc` |
| Maven settings | `m2-settings` | `~/.m2/settings.xml` |
| pip credentials | `pip-conf` | `~/.config/pip/pip.conf` |
| Docker Hub token | `docker-config` | `~/.docker/config.json` |
| Private SSH key | `ssh-key` | `~/.ssh/id_ed25519` |

Compare with sending secrets through the build context — see the security risks discussed in
[Build Context](build-context.md).

---

## SSH Agent Forwarding

`RUN --mount=type=ssh` forwards the host's SSH agent socket into the build container. This is
essential for cloning private repositories during a build.

### Usage

```dockerfile
# syntax=docker/dockerfile:1
FROM golang:1.22 AS builder
RUN --mount=type=ssh \
  git clone git@github.com:myorg/private-repo.git /src
```

```bash
docker build --ssh default .
```

### How It Works

1. BuildKit creates an SSH agent socket in the build container.
2. The host's SSH agent (`$SSH_AUTH_SOCK`) is forwarded to the build container via a Unix domain
   socket.
3. Commands inside the container that use SSH (e.g., `git clone`, `scp`) transparently use the
   forwarded agent.
4. No SSH keys ever enter the build context or image layers.

### Multiple SSH Keys

```dockerfile
RUN --mount=type=ssh,id=github \
  git clone git@github.com:myorg/repo.git /src
RUN --mount=type=ssh,id=gitlab \
  git clone git@gitlab.com:myorg/other.git /src2
```

```bash
docker build \
  --ssh github=$HOME/.ssh/id_ed25519 \
  --ssh gitlab=$HOME/.ssh/gitlab_ed25519 \
  .
```

### Security

- The socket is available only during the `RUN` instruction.
- The agent only signs challenges — the private key stays on the host.
- Use `$SSH_AUTH_SOCK` within the build to set git's SSH command:

```dockerfile
RUN --mount=type=ssh \
  export GIT_SSH_COMMAND="ssh -o StrictHostKeyChecking=accept-new" && \
  git clone git@github.com:myorg/repo.git /src
```

---

## BuildKit Cache Export

BuildKit can export its cache to external backends, enabling **cache sharing across CI runs** and
**distributed builds**.

### Modes

**Inline** — Cache data is embedded in the image manifest as an additional layer:

```bash
docker buildx build \
  --cache-to type=inline \
  --cache-from type=registry,ref=myapp:cache \
  -t myapp:latest \
  --push \
  .
```

Pros: No separate cache image to manage. Cons: Increases image size; only the final stage is cached.

**Registry** — Cache is stored as a separate manifest in a container registry:

```bash
docker buildx build \
  --cache-to type=registry,ref=myorg/myapp:cache \
  --cache-from type=registry,ref=myorg/myapp:cache \
  -t myapp:latest \
  --push \
  .
```

The cache manifest uses a special media type: `application/vnd.buildkit.cacheconfig.v0`. It
references cache layers as regular blobs in the registry.

**GHA (GitHub Actions)** — Cache is stored in GitHub Actions' native cache service:

```yaml
- name: Build with BuildKit cache
  uses: docker/build-push-action@v5
  with:
    cache-from: type=gha
    cache-to: type=gha,mode=max
```

**Local filesystem** — Cache is written to a local directory:

```bash
docker buildx build \
  --cache-to type=local,dest=/tmp/buildkit-cache \
  --cache-from type=local,src=/tmp/buildkit-cache \
  -t myapp:latest \
  .
```

**S3 / Azure Blob** — Cache stored in cloud object storage:

```bash
docker buildx build \
  --cache-to type=s3,region=us-east-1,bucket=my-cache,name=myapp \
  --cache-from type=s3,region=us-east-1,bucket=my-cache,name=myapp \
  -t myapp:latest \
  .
```

### Cache Mode: min vs max

- `mode=min` (default): Only cache the final stage's output. Faster export, but intermediate layer
  cache hits are limited.
- `mode=max`: Cache all stages, including intermediate layers. More cache export overhead but
  better hit rates across different builds.

```bash
docker buildx build \
  --cache-to type=registry,ref=myapp:cache,mode=max \
  --cache-from type=registry,ref=myapp:cache \
  -t myapp:latest \
  --push \
  .
```

### Garbage Collection

Standalone `buildkitd` runs a GC policy based on disk usage:

```toml
# /etc/buildkitd.toml
[worker.oci]
  gc = true
  gc-keepduration = 3600         # keep unused cache for 1 hour
  gc-reserved = "5GB"            # minimum free disk space
  gc-minfree = "10GB"            # start GC when free < 10GB
  gckeep = 10                    # minimum cache layers to keep

[[worker.oci.gcpolicy]]
  keep = "10GB"
  all = true
  filters = ["type==source.local", "type==exec.cachemount"]
```

GC runs periodically and when disk usage exceeds thresholds. It removes cache blobs that are no
longer referenced by any build.

---

## Strategic Analysis for Interview

### "Why does Docker need BuildKit?" (Motivation)

The legacy builder processed Dockerfiles sequentially with no DAG analysis — no parallel execution,
no cache mounts, no secrets support. BuildKit brings content-addressed caching, parallel stage
execution, secure build features (secrets, SSH), plugable frontends and workers, and cache export
for CI.

### "How does BuildKit cache work?" (Cache Architecture)

Each LLB op has a deterministic cache key = hash(op type + parameters + input hashes + metadata).
On cache hit, the solver loads the cached output instead of re-executing. Changes to the Dockerfile,
base image, context, or environment invalidate the affected ops. Cache can be exported to registries
(GHA, S3) for distributed CI reuse.

### "What is LLB?" (Low-Level Build)

LLB is a protobuf-defined DAG of operations: SourceOp (fetch), ExecOp (run), FileOp (copy/mkdir/rm),
BuildOp (nested sub-build). A Dockerfile frontend compiles Dockerfile instructions → LLB → solver
executes it. LLB is content-addressed: each op's output is identified by its hash.

### "How do cache mounts differ from regular layers?" (Persistence)

Cache mounts persist data across builds but never appear in the final image layers. They are
identified by an ID, stored in BuildKit's cache store, and garbage-collected based on TTL/disk
pressure. Regular layers are immutable and become part of the exported image.

### "How do you handle secrets in BuildKit?" (Security)

`RUN --mount=type=secret` mounts secret data as a tmpfs available only to that specific RUN
instruction. The data is passed via pipe from the client, never written to a layer, and freed after
execution. `RUN --mount=type=ssh` forwards the host SSH agent socket, keeping private keys on the
host.

### "How does multi-stage build parallelization work?" (DAG execution)

BuildKit analyses the LLB DAG to find independent subgraphs. Stages with no dependency on each
other execute in parallel. For example, `FROM golang:1.21 AS builder` and `FROM alpine:3.19 AS
runtime` in the same Dockerfile run concurrently if `runtime` does not reference `builder` until
the `COPY --from=builder` step.

### Cross-References

- [Docker Architecture](docker-architecture.md) — how BuildKit relates to
  dockerd/containerd
- [Build Context](build-context.md) — context handling in BuildKit
- [How Docker Builds Images](how-docker-builds-images.md) — pipeline integration
- [Docker Hardened Images](product-strategy/docker-hardened-images.md) — SLSA L3 with BuildKit
