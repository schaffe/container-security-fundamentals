---
title: "How Docker Builds Images"
section: "Docker"
order: 33
---

# How Docker Builds Images

Building a container image looks like a single command — `docker build .` — but behind the curtain it
is a multi-stage pipeline involving parsing, DAG construction, cache resolution, sandboxed execution,
filesystem differencing, layer compression, and manifest assembly. This article walks through every
stage from `docker build` to a publishable image.

The pipeline is broken into seven stages:

1. **Dockerfile Parsing** — lex and parse the Dockerfile into an AST.
2. **Frontend Translation** — translate the AST into a low-level build graph (LLB).
3. **LLB Graph Resolution** — resolve cache keys, prune unreachable ops, linearise the DAG.
4. **Solver Execution** — execute ops in sandboxed containers, capture filesystem diffs.
5. **Layer Export** — produce content-addressed layer tarballs.
6. **Image Manifest Assembly** — assemble config.json and manifest.json.
7. **Push** — upload layers and manifests to a container registry.

---

## Stage 1 — Dockerfile Parsing

### The Lexer and Parser

BuildKit's Dockerfile parser lives in `moby/buildkit/pkg/dockerfile/parser`. It is a hand-written
recursive-descent parser — not a generated one — because Dockerfile syntax is simple enough that a
parser generator adds more complexity than it removes.

The parser has two phases:

**Lexer.** The lexer reads the Dockerfile character-by-character and emits tokens: instruction names
(`FROM`, `RUN`, `COPY`, etc.), whitespace, quoted strings, comments (lines starting with `#`), and
heredoc markers. It strips `\` line-continuation characters and normalises line endings.

**Parser.** The parser consumes the token stream and builds an AST of `*parser.Node` values. Each
node has three fields:

| Field     | Type              | Purpose                                       |
|-----------|-------------------|-----------------------------------------------|
| `Value`   | `string`          | The raw text of the node (instruction + args) |
| `Next`    | `*Node`           | Next sibling node (next line / instruction)   |
| `Children`| `[]*Node`         | Child nodes (arguments, heredocs, flags)      |

A `FROM` instruction becomes a node whose `Value` is `FROM ubuntu:22.04`. An `ARG` before the first
`FROM` is attached as a child of the root node. `RUN` with a heredoc gets the heredoc body as a child
node.

### Supported Instructions

The parser recognises every Dockerfile instruction:

`FROM`, `RUN`, `CMD`, `LABEL`, `MAINTAINER`, `EXPOSE`, `ENV`, `ADD`, `COPY`, `ENTRYPOINT`,
`VOLUME`, `USER`, `WORKDIR`, `ARG`, `ONBUILD`, `STOPSIGNAL`, `HEALTHCHECK`, `SHELL`.

`MAINTAINER` is deprecated but still parsed for backward compatibility.

### Heredoc Support

BuildKit extends the standard Dockerfile syntax with heredocs in `RUN`, `COPY`, and `FROM`
instructions. A heredoc allows multi-line inline content without escaping:

```Dockerfile
RUN <<EOF
apt-get update
apt-get install -y curl jq
EOF
```

The parser detects the `<<EOF` marker and reads until the closing `EOF` on its own line, creating a
child node with the heredoc body. The frontend later translates this into an equivalent `RUN` with
the content piped into the shell.

### Example AST Output

For a minimal Dockerfile:

```Dockerfile
FROM alpine:3.19
RUN apk add curl
COPY app.sh /app.sh
CMD ["/app.sh"]
```

The parser produces an AST that (simplified to JSON) looks like:

```json
{
  "value": "",
  "children": [
    {
      "value": "FROM alpine:3.19",
      "next": {
        "value": "RUN apk add curl",
        "next": {
          "value": "COPY app.sh /app.sh",
          "next": {
            "value": "CMD [\"/app.sh\"]"
          }
        }
      }
    }
  ]
}
```

Each instruction is a sibling (`Next` pointer), and the root node has no value — it is a container
for the instruction list.

---

## Stage 2 — Frontend Translation (Dockerfile → LLB)

### The dockerfile.v1 Frontend

Once the Dockerfile is parsed into an AST, BuildKit's **dockerfile.v1 frontend** walks the AST and
translates each instruction into one or more **LLB (Low-Level Build) operations**. The frontend is
reimplemented entirely in Go — it does **not** shell out to Docker or any external tool.

LLB is a protobuf-based intermediate representation that describes a build graph. Each node in the
LLB graph is an **op** that produces one or more outputs (typically a filesystem snapshot). Ops
connect to form a directed acyclic graph (DAG).

### Translation Rules

**`FROM` → `SourceOp`.** Every `FROM` becomes a `SourceOp` that pulls a base image (or scratches an
empty filesystem). The op carries the image reference, platform selection, and credentials. If the
image is already cached locally, the op resolves immediately without a network fetch.

```json
{
  "op": "SourceOp",
  "identifier": "docker-image://docker.io/library/alpine:3.19",
  "platform": "linux/amd64"
}
```

**`RUN` → `ExecOp`.** Every `RUN` becomes an `ExecOp` that creates a temporary container from the
current snapshot, runs the command, and captures the filesystem diff. The op carries the command
array, environment variables, working directory, and metadata. The diff between the snapshot before
and after execution becomes a new layer.

```json
{
  "op": "ExecOp",
  "meta": {
    "args": ["/bin/sh", "-c", "apk add curl"],
    "env": ["PATH=/usr/local/sbin:..."],
    "cwd": "/"
  },
  "mounts": [
    {"input": 0, "output": 0, "type": "bind"}
  ]
}
```

**`COPY` → `FileOp.Copy`.** `COPY` and `ADD` become `FileOp` actions — specifically `Copy` actions.
The action copies files from one snapshot (the build context or a previous stage) into the current
snapshot. `ADD` with a URL becomes a `SourceOp` followed by a `FileOp.Copy`. `ADD` with automatic
tar extraction sets a flag on the action.

```json
{
  "op": "FileOp",
  "actions": [
    {
      "input": 0,
      "secondaryInput": 1,
      "output": 0,
      "action": "COPY",
      "src": "app.sh",
      "dest": "/app.sh"
    }
  ]
}
```

**`ENV` / `WORKDIR` / `USER` → metadata on `ExecOp`.** These instructions do **not** produce their
own layers. Instead, they modify metadata that gets attached to the *next* `ExecOp`. The frontend
maintains a running state map for environment variables, working directory, and user. When the next
`RUN` executes, it inherits that state. The metadata is also written into the final image
configuration.

This is an important optimisation — setting `ENV FOO=bar` followed by `RUN make` produces **one**
layer (the `RUN` diff), not two.

**`EXPOSE` / `LABEL` → image config metadata.** These are stored in the image configuration and
do not produce any ops at all.

### Multi-Stage Builds

Each `FROM` starts a new sub-graph. The frontend tracks stage dependencies: if `COPY --from=builder`
references stage `builder`, the frontend wires the output of builder's final snapshot as an input to
the current `FileOp`.

Unused stages are pruned: if stage `builder` has a `FROM ubuntu` but is never referenced by a
`COPY --from=builder`, the frontend drops it from the graph entirely. This prevents pulling base
images that no output stage needs.

```Dockerfile
# Stage 1
FROM golang:1.22 AS builder
WORKDIR /src
COPY . .
RUN go build -o /app

# Stage 2
FROM alpine:3.19
COPY --from=builder /app /app
CMD ["/app"]
```

This produces an LLB graph with two roots: `golang:1.22` (builder) and `alpine:3.19` (final stage).
The `alpine` stage's `COPY` op has an additional input pointing to the builder's final snapshot.
The builder's `RUN go build` op is reachable only through that `COPY` reference; nothing else in
the final stage depends on the base `golang` image beyond the compiled binary.

---

## Stage 3 — LLB Graph Resolution

### The Solver

BuildKit's **solver** is the component that takes the LLB graph and drives it to completion. It
lives in `moby/buildkit/solver`. The solver does three things:

1. **Builds the DAG.** It walks the LLB ops, creates a dependency graph (each op's inputs are its
   dependencies), and topologically sorts it. Ops with no dependencies (leaf `SourceOp`s) are
   ready immediately.

2. **Computes cache keys.** For each op, the solver computes a **cache key** — a digest (SHA-256)
   of the op's definition and its inputs' cache keys. If the same key exists in the local cache or
   a remote cache (e.g. a registry cache), the op is **cache hit** and its output is reused without
   re-execution. If the key is absent, the op is **cache miss** and must be executed.

3. **Schedules execution.** Cache-miss ops are dispatched to workers (runc, containerd) for
   execution. Independent ops (e.g. two `FROM` pulls for different stages) run in parallel.

### Cache Key Computation

The cache key for an `ExecOp` includes:

- The command string and arguments.
- Environment variables (filtered by `--build-arg` awareness).
- The working directory.
- The cache keys of all input snapshots.
- The contents of files referenced by `COPY` (via checksums, not full content).

A `SourceOp`'s cache key is the image digest (not the tag — tags are mutable). If two builds both
reference `alpine:3.19`, but the remote `alpine:3.19` has a different digest than yesterday's pull,
the cache key changes and the base image is re-pulled.

### Parallelism

Because the solver processes the DAG and not the Dockerfile's linear order, it can parallelise
aggressively:

- Two `FROM` lines at the start of separate stages are pulled concurrently.
- Multiple `COPY` ops from the same source can run in parallel.
- A `RUN` in one stage and a `RUN` in an independent stage execute simultaneously.

The `--progress=plain` flag shows this parallelism:

```
#1 [stage-0  1/2] FROM golang:1.22@sha256:abc...
#2 [stage-1  1/2] FROM alpine:3.19@sha256:def...
#1 [stage-0  2/2] RUN go build -o /app
#2 [stage-1  2/2] COPY --from=stage-0 /app /app
```

Lines `#1` and `#2` execute concurrently because the solver determined neither depends on the
other.

---

## Stage 4 — Solver Execution

### ExecOp Execution

When the solver schedules an `ExecOp`, BuildKit:

1. **Creates a temporary container** from the current snapshot using the configured worker (runc or
   containerd). The snapshot is a read-only mount; BuildKit adds a writable overlay on top.

2. **Sets up the execution environment:** mounts, environment variables, working directory, user,
   resource limits (CPU, memory), security options (seccomp, AppArmor, capabilities).

3. **Runs the command** inside the container. The process's stdout and stderr are streamed back to
   the client for display.

4. **Captures the filesystem diff.** After the command exits, BuildKit compares the writable layer
   to the original snapshot. The difference is the new layer's content.

5. **Commits the snapshot.** The writable layer is committed as a new immutable snapshot, which
   becomes the input to the next op.

### Snapshotters

BuildKit uses **snapshotters** to manage filesystem snapshots efficiently. The default snapshotter
on Linux is `overlayfs` — it uses Linux's OverlayFS kernel driver to create lightweight
copy-on-write layers. Each snapshot is a directory with:

- `fs/` — the full filesystem tree (for non-overlay snapshotters).
- Metadata tracking parent-child relationships.

The `native` snapshotter creates full copies of the filesystem (slower, more space). The
`fuse-overlayfs` snapshotter works on systems where the kernel lacks OverlayFS (e.g. older distros,
rootless mode).

### FileOp.Copy Execution

`FileOp.Copy` is simpler than `ExecOp` — no container is created. BuildKit reads files from the
source snapshot and writes them into the destination snapshot using Go's `io.Copy`. The copy is
chunked and checksummed. If the source is a tar archive (as in `ADD`), BuildKit streams the tar
directly into the destination snapshot without extracting to an intermediate directory.

### Execution Traces

Setting `BUILDKIT_PROGRESS=plain` shows every op's status in real time:

```
#1 [internal] load build definition from Dockerfile
#1 transferring dockerfile: 352B done
#2 [internal] load metadata for docker.io/library/alpine:3.19
#2 DONE 1.2s
#3 [internal] load .dockerignore
#3 transferring context: 2B done
#4 [stage-0 1/2] FROM docker.io/library/alpine:3.19@sha256:...
#4 resolve docker.io/library/alpine:3.19@sha256:... 0.0s done
#4 sha256:abc... 0B / 7.04MB 0.1s
#4 sha256:abc... 7.04MB / 7.04MB 0.5s done
#4 extracting sha256:abc... 0.2s done
#5 [stage-0 2/2] RUN apk add curl
#5 0.294 fetch https://dl-cdn.alpinelinux.org/...
#5 1.586 (1/1) Installing curl (8.5.0-r0)
#5 1.626 Executing busybox-1.36.1-r15.trigger
#5 1.626 OK: 8 MiB in 19 packages
#5 DONE 1.7s
```

Each `#[N]` prefix identifies a vertex (op) in the build graph. The two-part numbers (e.g. `1/2`)
are stage progress indicators — the first number is the current op index within that stage, the
second is the total ops for that stage.

---

## Stage 5 — Layer Export

### The Differ

After an `ExecOp` completes, BuildKit's **differ** walks the before and after snapshots to produce
a tar archive of changes. The differ lives in `moby/buildkit/cache/blobs`.

The differ is optimised for OverlayFS: it reads the overlay's upper directory (the writable layer)
and lists every file. Each file falls into one of three categories:

| Status     | Meaning                                | Tar header type       |
|------------|----------------------------------------|-----------------------|
| Added      | File exists in upper, not in lower     | Regular file          |
| Modified   | File exists in both, different content | Regular file          |
| Deleted    | File exists in lower, not in upper     | Whiteout entry        |
| Unchanged  | File exists in both, same content      | Skipped (not in tar)  |

Unchanged files are **not** included in the layer tar — this is what makes layers small. A layer
represents only the delta from the previous state.

### Whiteout Files

On OverlayFS, when a file is deleted from the upper directory, the filesystem leaves a **whiteout**
character device (0:0) in its place. The differ converts these whiteout devices into OCI-compatible
tar entries:

- **Whiteout file:** A tar entry named `.wh.<filename>` marks that `<filename>` was deleted.
- **Opaque directory:** A tar entry named `.wh..wh..opq` in a directory marks all pre-existing
  entries under that directory as deleted (used when the entire directory was removed and
  re-created).

When a container runtime applies layers, it interprets whiteout entries: any `.wh.` file causes the
corresponding real file to be deleted from the lower layers' view. Opaque markers clear all
contents of a directory before applying the new layer's contents.

### Content-Addressed Layers

Each layer tar is content-addressed: its digest (SHA-256) is its identity. BuildKit computes two
digests per layer:

- **Uncompressed digest** — SHA-256 of the raw tar stream. This goes into `rootfs.diff_ids` in the
  image config.
- **Compressed digest** — SHA-256 of the gzip-compressed tar stream. This goes into the manifest's
  `layers[].digest`.

Because layers are content-addressed, identical layers across different images share the same blob
on disk and in the registry. If two unrelated builds both produce a layer with the same SHA-256
digest, the registry stores it once.

### What FROM Layers Look Like

When an image references `alpine:3.19`, its layers already exist in the registry. BuildKit does
**not** re-export those layers — the final image's manifest references the base image's existing
layer digests. Only layers produced during the current build are new blobs.

This means a Dockerfile:

```Dockerfile
FROM alpine:3.19
RUN echo hello > /hello
```

Produces a single new layer (the `RUN` diff). The final image references alpine's existing layers
plus the new one. The registry does not duplicate alpine's data.

---

## Stage 6 — Image Manifest Assembly

### config.json

After all layers are exported, BuildKit assembles the **image configuration** (`config.json`). This
JSON object describes the image's metadata and hardware requirements. Fields include:

```json
{
  "architecture": "amd64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": [
      "sha256:abc...",
      "sha256:def..."
    ]
  },
  "history": [
    {
      "created": "2024-01-15T10:00:00Z",
      "created_by": "FROM alpine:3.19",
      "comment": "buildkit.dockerfile.v1"
    },
    {
      "created": "2024-01-15T10:00:01Z",
      "created_by": "RUN apk add curl",
      "comment": "buildkit.dockerfile.v1"
    }
  ],
  "config": {
    "Env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "Cmd": ["/bin/sh"],
    "ExposedPorts": null,
    "Volumes": null,
    "WorkingDir": "/",
    "Entrypoint": null,
    "Labels": null
  }
}
```

Key details:

- **`rootfs.diff_ids`** lists uncompressed layer digests in order. The runtime applies layers in
  this exact sequence. Each digest is the SHA-256 of the **uncompressed** layer tar (before gzip).
- **`history`** records each build step. `docker history --no-trunc` displays this list. The
  `created_by` field stores the original Dockerfile instruction.
- **`config`** contains the runtime defaults: entrypoint, command, environment variables, working
  directory, ports, volumes, and labels. These defaults are used by the container runtime when a
  user runs `docker run` without overriding them.

### manifest.json

The **image manifest** (`manifest.json`) references the config and the layer blobs:

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "config": {
    "mediaType": "application/vnd.oci.image.config.v1+json",
    "digest": "sha256:123...",
    "size": 1420
  },
  "layers": [
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:abc...",
      "size": 7040000
    },
    {
      "mediaType": "application/vnd.oci.image.layer.v1.tar+gzip",
      "digest": "sha256:def...",
      "size": 123
    }
  ]
}
```

The `layers[]` entries use **compressed** digests — the SHA-256 of the gzipped tar. Each entry
includes the compressed size. The runtime downloads these blobs and decompresses them before
applying.

BuildKit uses OCI media types by default (`application/vnd.oci.*`). Docker media types
(`application/vnd.docker.*`) are also supported for backward compatibility with older registries.

### docker history --no-trunc

The `history` field in config.json is what `docker history --no-trunc` displays:

```bash
$ docker history --no-trunc my-image:latest
IMAGE          CREATED       CREATED BY                                      SIZE
sha256:def...  2 hours ago   RUN /bin/sh -c apk add curl                      5.2MB
sha256:abc...  2 hours ago   COPY app.sh /app.sh                             512B
sha256:base... 2 weeks ago   FROM alpine:3.19                                7.05MB
```

Each line corresponds to one entry in `history[]`. The `SIZE` column is the compressed layer size
from the manifest (or `0B` for instructions that do not produce layers, like `ENV` or `WORKDIR`).

---

## Stage 7 — Push

### Parallel Layer Upload

When `--push` is specified, BuildKit uploads all new layers to the target registry. Layers are
pushed **in parallel** — the solver does not wait for layer N to finish before starting layer N+1.

The upload protocol follows the OCI Distribution Spec:

1. **POST** `/v2/<name>/blobs/uploads/` — initiate an upload session. The registry returns a
   session URL.
2. **PATCH** `<session-url>` — upload chunk(s) of blob data. BuildKit uses chunked upload with
   `Content-Range` headers.
3. **PUT** `<session-url>?digest=sha256:...` — finalise the upload. The registry computes the
   digest and verifies it matches the declared digest.

If a blob already exists on the registry (same digest), BuildKit skips the upload — it sends a
`HEAD` request first and checks the registry's response:

```bash
HEAD /v2/<name>/blobs/sha256:abc...

# Response: 200 OK → blob exists, skip upload
# Response: 404 Not Found → blob missing, initiate upload
```

### Manifest Push

The manifest is pushed **last**, after all layers are confirmed present on the registry. This makes
the push atomic: if the client disconnects mid-push, the registry never sees an incomplete manifest
pointing to missing blobs.

```bash
PUT /v2/<name>/manifests/<tag>
Content-Type: application/vnd.oci.image.manifest.v1+json
```

The manifest content type matters — registries use it to validate the manifest structure. Using the
wrong media type can cause rejections.

### Output Types

BuildKit supports multiple output formats via the `--output` (or `-o`) flag:

| Type       | Flag                          | Description                                 |
|------------|-------------------------------|---------------------------------------------|
| `image`    | `--output type=image`         | Push to registry (same as `--push`)         |
| `docker`   | `--output type=docker`        | Export as Docker tar (`docker load`)        |
| `oci`      | `--output type=oci`           | Export as OCI layout tar                    |
| `local`    | `--output type=local`         | Export filesystem to a local directory      |
| `tar`      | `--output type=tar`           | Export filesystem as a tar archive          |
| `registry` | `--output type=registry`      | Push to one or more registries (deprecated) |

The `type=image` output is equivalent to `--push` but allows fine-grained control over the push
destination:

```bash
buildctl build \
  --output type=image,name=docker.io/user/my-app:latest,push=true
```

The `type=docker` output produces a single tar file compatible with `docker load`:

```bash
buildctl build \
  --output type=docker,name=my-app:latest,dest=my-app.tar
```

---

## Cross-References

- [BuildKit Internals](../articles/32-buildkit-internals.md) — LLB deep dive, cache mounts, and
  advanced caching strategies.
- [Build Context](../articles/31-build-context.md) — how the build context is tarred, shipped, and
  filtered by `.dockerignore`.
- [Image Layers and Storage Drivers](../articles/34-image-layers-storage-drivers.md) — how layers
  are stored on disk and mounted by overlayfs, devicemapper, and btrfs.
- [Docker Content Trust](../articles/27-docker-content-trust.md) — how Notary signs image manifests
  for tamper-proof distribution.
- [Docker Hardened Images](../articles/26-docker-hardened-images.md) — attestations, SBOM
  generation, and SLSA provenance during builds.
- [Multi-Architecture and Security](../articles/15-multi-arch-security.md) — multi-arch manifests
  and platform-aware image references.
