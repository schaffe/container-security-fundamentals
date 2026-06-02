---
title: "Kaniko vs Docker Builds"
section: "Docker"
order: 36
---

# Kaniko vs Docker Builds

## Overview

Container image building in Kubernetes presents a security dilemma: mounting the Docker socket into a
pod gives that pod node-level root access. Kaniko offers a daemonless alternative built by Google.
This article covers what Kaniko is, how it works, where it shines, and when you should stick with
Docker BuildKit.

---

## What Is Kaniko

Kaniko is an open-source tool from Google for building container images from a Dockerfile **without
depending on a Docker daemon**. The executor runs as a container image itself
(`gcr.io/kaniko-project/executor:latest`) and produces standard OCI-compatible images.

It is part of Google's container tools ecosystem, which includes `distroless`, `ko` (Go builders),
`crane`, and `gcrane`. Kaniko fills the gap for in-cluster image building where security requirements
forbid privileged containers or Docker socket access.

---

## Why Kaniko Exists

### The Docker Socket Problem

In a typical Kubernetes CI pipeline, building an image requires a Docker daemon. The standard
workaround is to mount the host's Docker socket into the CI pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: docker-builder
spec:
  containers:
  - name: docker
    image: docker:24.0
    command: ["docker", "build", "-t", "myapp", "."]
    volumeMounts:
    - name: dockersock
      mountPath: /var/run/docker.sock
  volumes:
  - name: dockersock
    hostPath:
      path: /var/run/docker.sock
```

This works, but the security implications are severe:

- **Node-level root access**: The Docker socket is a Unix socket owned by `root`. Any process
  with access to it can create containers on the **host**, not inside the pod. A malicious
  Dockerfile or compromised build step can escape the build container and access the node.
- **No isolation**: Docker containers on the host share the host's kernel, cgroups, and network.
  A build pod with `docker.sock` is effectively a root shell on the node.
- **Audit trail**: Standard Kubernetes RBAC does not control Docker socket access. If a pod has
  the socket, it bypasses all Kubernetes access controls.

### The Privileged Container Problem

An alternative to mounting the Docker socket is running Docker-in-Docker (DinD) — running a Docker
daemon inside the pod alongside the build client. This requires the pod to be **privileged**:

```yaml
securityContext:
  privileged: true  # DinD requires this
```

A privileged container has all capabilities, no seccomp filtering, and can access host devices.
This is often blocked by admission controllers (PodSecurity admission, OPA/Gatekeeper) in hardened
clusters.

### What Kaniko Solves

Kaniko runs as a non-privileged container. It does not need `/var/run/docker.sock`, does not require
`privileged: true`, and does not start a daemon. It builds images entirely in userspace using
kernel features available to any container ([chroot](../articles/30-docker-architecture.md#chroot-and-pivot_root),
[ptrace](../articles/12-seccomp.md#ptrace)).

See [Docker Architecture](../articles/30-docker-architecture.md) for why the daemon model requires
privileged access.

---

## Kaniko Architecture

Kaniko runs as a single process inside a container. There is no daemon, no socket, no background
server. When the Kaniko executor starts, it follows this sequence:

1. **Parse the Dockerfile** — Tokenise and validate instructions.
2. **Pull the base image** — Download the base image manifest and layers from the registry.
3. **Extract the base image** — Unpack layers into the target root filesystem.
4. **Execute each instruction** — For each Dockerfile instruction:
   - Apply a [`chroot`](../articles/30-docker-architecture.md#chroot-and-pivot_root) to the target rootfs.
   - Run the command (for `RUN`), copy files (for `COPY`/`ADD`), or apply metadata.
   - Snapshot the filesystem to detect changes.
   - Package changed files as a tar layer.
   - Push the layer to the registry (optional, configurable).
5. **Push the final manifest** — Assemble and push the image manifest pointing to all pushed layers.

```
+-------------+     +-------------+     +--------------+
| Parse       | --> | Pull base   | --> | Extract to   |
| Dockerfile  |     | image       |     | /kaniko/root |
+-------------+     +-------------+     +--------------+
                                              |
                                              v
                                    +-------------------+
                                    | For each          |
                                    | Dockerfile step:  |
                                    |   chroot + exec   |
                                    |   snapshot (diff) |
                                    |   push layer      |
                                    +-------------------+
                                              |
                                              v
                                    +-------------------+
                                    | Push final        |
                                    | image manifest    |
                                    +-------------------+
```

### Key Design Decisions

**No daemon.** Kaniko is a single binary. It does not fork, does not listen on sockets, and does
not require setup scripts. Simpler to deploy, no daemon crashes to handle.

**Userspace filesystem operations.** Kaniko does not use overlayfs, device-mapper, or any kernel
union filesystem. It manages the filesystem by extracting layers into a directory tree and using
[ptrace](../articles/12-seccomp.md#ptrace) to snapshot changes.

**Push-as-you-go.** By default, Kaniko pushes each layer to the registry as it is built, rather
than assembling all layers locally and pushing at the end. This reduces local disk requirements
and allows partial progress.

---

## Filesystem Snapshot Mechanics

Kaniko's core technical challenge is detecting what files changed when a `RUN` instruction executes.
Without a union filesystem to diff layers, Kaniko uses an approach based on
[chroot](../articles/30-docker-architecture.md#chroot-and-pivot_root) and
[ptrace](../articles/12-seccomp.md#ptrace).

### Chroot-Based Execution

For each `RUN` instruction, Kaniko creates a subprocess that is
[`chroot`ed](../articles/30-docker-architecture.md#chroot-and-pivot_root) into the target rootfs.
The command runs inside this
[chroot](../articles/30-docker-architecture.md#chroot-and-pivot_root), with the filesystem
directly accessible at `/` from the subprocess's perspective.

```bash
# Kaniko's chroot equivalent (simplified)
chroot /kaniko/root /bin/sh -c "apt-get install -y curl"
```

### Change Detection via Ptrace

Kaniko uses [`ptrace`](../articles/12-seccomp.md#ptrace) (the `PTRACE_SYSCALL` mechanism) to intercept filesystem-related system calls
made by the build process and its children:

- `open()`, `creat()`, `unlink()`, `rename()`, `link()`, `symlink()`, `mkdir()`, `rmdir()`,
  `truncate()`, `ftruncate()`, `write()`
- Also tracks `execve()` to follow child processes.

Every syscall that modifies the filesystem is recorded. After the command completes, Kaniko has a
list of every file that was created, modified, or deleted.

### Snapshot via Tar

With the list of changed paths, Kaniko creates a tar archive of just those files from the target
rootfs:

1. Read each changed file from `/kaniko/root`.
2. Compute its SHA-256 digest.
3. Compare against the digest from the previous layer.
4. If the digest changed (or the file is new), include it in the layer tarball.
5. If a file was deleted, record a whiteout entry (`.wh.<filename>`).

The resulting tarball is a standard OCI layer that can be pushed to any registry.

### Performance Implication

Ptrace-based change detection is slower than overlayfs diffs (which are O(1) at the VFS level).
For each `RUN` instruction:

- Every syscall is intercepted and evaluated.
- After execution, Kaniko walks the entire changed-path list and tars matching files.

For builds with many small file changes (e.g., `npm install` writing thousands of files), this
overhead adds up. For single-file changes (`COPY main.go .`), the overhead is minimal.

---

## Layer Caching in Kaniko

Kaniko supports caching, but with important differences from BuildKit.

### Remote Registry Cache

Kaniko stores cache in the container registry itself using the `--cache` flag:

```bash
kaniko \
  --context=git://github.com/myorg/myapp.git \
  --destination=myapp:latest \
  --cache=true
```

When `--cache=true` is set, Kaniko queries the registry for a cache image before executing each
instruction. The cache key is derived from:
- The base image digest at the current snapshot point
- The Dockerfile instruction text
- The build context checksum (for `COPY`/`ADD`)

If a matching layer exists in the cache image, Kaniko downloads it instead of re-executing the
instruction.

### Kaniko vs BuildKit Caching

| Aspect | BuildKit | Kaniko |
|--------|----------|--------|
| Cache storage | Content-addressed, multiple backends (local, registry, GHA, S3) | Registry only |
| Cache granularity | Per-op (LLB node) | Per-Dockerfile instruction |
| Cache mount sharing | Yes (`--mount=type=cache`) across builds | Not supported |
| Cache export | Separate manifests (inline, registry, GHA, S3, Azure) | Embedded in target image |
| Cache hit speed | Lookup by content hash (local daemon); sub-millisecond | Network call to registry per instruction |

Kaniko's registry-only cache means every `RUN` instruction incurs at least one registry API call
to check for a cached layer. In high-latency environments or with many small `RUN` instructions,
this can be slower than no caching at all.

### Cache Configuration

```bash
# Enable cache with custom repository
kaniko \
  --context=dir:///workspace \
  --destination=myapp:latest \
  --cache=true \
  --cache-repo=my-registry/cache

# Warm the cache with a known good build
kaniko \
  --context=dir:///workspace \
  --destination=myapp:latest \
  --cache=true \
  --no-push
```

The `--no-push` flag rebuilds and caches layers without pushing the final image — useful for
pre-warming the cache in CI before the actual build.

---

## Comparison: Kaniko vs Docker BuildKit

| Feature | Docker BuildKit | Kaniko |
|---------|---------------|--------|
| Architecture | Daemon-based (containerd/buildkitd) | Standalone binary (userspace) |
| Root requirement | Needs root/privileged by default | Can run as non-root |
| Rootless mode | Yes (with buildkitd --oci-worker-no-process-sandbox) | Yes (default) |
| Layer caching | Content-hash, shared across builds | Only remote registry caching (--cache=true) |
| Cache mounts | Full support (--mount=type=cache) | Not supported |
| Secrets | --secret, --ssh, --mount=type=secret | Via Kubernetes secrets (mounted files) |
| SSH forwarding | --mount=type=ssh | Not supported natively |
| Multi-stage builds | Full support + parallel stages | Full support (sequential stages) |
| Speed | Fast (parallel DAG execution, cached) | Slower (sequential, ptrace overhead) |
| Dockerfile compat | Full + extended (heredocs, --mount types) | High (limited --mount support) |
| Use case | Dev machines, CI with Docker socket | Kubernetes CI (no Docker socket) |
| Push method | Direct (parallel blob uploads) | Direct (sequential by default) |
| OCI output | Yes (--output type=oci) | Yes (default) |
| Multi-arch builds | Yes (--platform with QEMU) | Build per platform, stitch with manifest-tool |
| Container registry | Any OCI-compatible | Any OCI-compatible |
| Plugin/API | Gateway frontends, LLB | None (CLI flags only) |
| Community | Moby project, Docker Inc. | Google, CNCF sandbox |

---

## When to Use Which

### Use Docker BuildKit When

- **You have Docker socket access.** Local development, CI runners with Docker-in-Docker, or
  trusted environments where mounting the socket is acceptable.
- **Speed matters.** BuildKit's parallel DAG execution, content-addressed local cache, and cache
  mounts can be 2-10x faster than Kaniko for complex multi-stage builds.
- **You need BuildKit-exclusive features.** Cache mounts (`--mount=type=cache`), secret mounts,
  SSH forwarding, heredoc syntax, or the gateway frontend architecture.
- **You need multi-arch builds.** BuildKit handles `--platform linux/amd64,linux/arm64` in a
  single invocation with QEMU emulation or cross-compilation.

### Use Kaniko When

- **You are building images in Kubernetes** and PodSecurity standards block privileged containers
  or Docker socket mounts. This is the primary Kaniko use case.
- **Your CI platform already integrates it.** GitLab CI has native Kaniko support, as does
  Tekton CD, Argo Workflows, and Jenkins X. The integration is a one-line config change.
- **You cannot run a daemon.** BuildKitd is a long-running process that needs persistent state
  and garbage collection. Kaniko is ephemeral — start, build, exit.
- **Compliance requires no host-level access.** Auditors flagging Docker socket mounts or
  privileged containers get a clean pass with Kaniko.

### GitLab CI Example

```yaml
kaniko-build:
  stage: build
  image:
    name: gcr.io/kaniko-project/executor:latest
    entrypoint: [""]
  script:
    - kaniko
        --context "${CI_PROJECT_DIR}"
        --dockerfile "${CI_PROJECT_DIR}/Dockerfile"
        --destination "${CI_REGISTRY_IMAGE}:${CI_COMMIT_TAG:-latest}"
  rules:
    - if: $CI_COMMIT_TAG
```

### Tekton Example

```yaml
apiVersion: tekton.dev/v1beta1
kind: Task
metadata:
  name: kaniko-build
spec:
  steps:
  - name: build-and-push
    image: gcr.io/kaniko-project/executor:latest
    args:
    - --context=dir:///workspace/source
    - --destination=my-registry/myapp:latest
    - --cache=true
```

### Argo Workflows Example

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Workflow
metadata:
  generateName: kaniko-build-
spec:
  entrypoint: build
  templates:
  - name: build
    container:
      image: gcr.io/kaniko-project/executor:latest
      args:
      - --context=dir:///workspace
      - --destination=my-registry/myapp:latest
      - --cache=true
```

---

## Alternatives

Kaniko and BuildKit are not the only options. Several other tools address the same problem space.

### Buildah

Buildah is part of the Podman ecosystem (Red Hat). It builds OCI images without a daemon, using
`overlayfs` mounted inside a user namespace for change detection:

```bash
buildah bud -t myapp .
```

Key differences from Kaniko:

- **Overlayfs-based diff**: Buildah mounts layers as overlayfs lowerdirs and uses the upperdir to
  detect changes. This is much faster than Kaniko's [ptrace](../articles/12-seccomp.md#ptrace) approach — no syscall interception
  overhead.
- **User namespace support**: Buildah can run in a user namespace, mapping a non-root UID to root
  inside the namespace. This gives it filesystem capabilities without `CAP_SYS_ADMIN`.
- **Mount support**: Buildah supports `--mount=type=cache` (via buildah-cache) and
  `--mount=type=secret`, similar to BuildKit.
- **Multi-stage**: Full support.

Buildah is a strong Kaniko alternative for Kubernetes CI when user namespaces are available (kernel
5.3+). The performance is closer to BuildKit than Kaniko.

### img

`img` is a wrapper around BuildKit that runs it in an isolated container without the Docker daemon.
It spawns a temporary `buildkitd` inside a container, builds the image, and tears it down:

```bash
img build -t myapp .
```

img trades simplicity for performance — you get BuildKit's caching and parallel execution without
the daemon's persistent state. However, it requires running nested containers (privileged or with
`--security-opt seccomp=unconfined --security-opt apparmor=unconfined`), which may recreate the
security concerns Kaniko avoids.

### makisu

Makisu is Uber's in-cluster image builder. It uses overlayfs mounts in a user namespace for
change detection, similar to Buildah:

- **Overlayfs-based**: Faster than Kaniko's [ptrace](../articles/12-seccomp.md#ptrace).
- **Registry-level caching**: Makisu computes content-hash cache keys and stores cache manifests in
  the registry, like BuildKit's `--cache-to type=registry`.
- **Parallel layer uploads**: Pushes multiple layers concurrently.
- **No root required**: Runs as non-root with user namespaces.

Makisu is less actively maintained than Kaniko or Buildah, but it has the best caching performance
among the daemonless builders.

### Comparison of Alternatives

| Feature | Kaniko | Buildah | img | makisu |
|---------|--------|---------|-----|--------|
| Diff mechanism | ptrace | overlayfs | BuildKit (overlayfs) | overlayfs |
| Rootless | Yes | Yes (user ns) | No (needs priv) | Yes (user ns) |
| Layer caching | Registry-only | Local + registry | BuildKit full | Content-hash (local + registry) |
| Cache mounts | No | Yes | Yes | No |
| Performance | Slow (ptrace) | Medium | Fast (BuildKit) | Fast (overlayfs) |
| Active maintenance | Yes (Google) | Yes (Red Hat) | Low | Low |
| Kubernetes integration | Native (Tekton, GitLab, Argo) | Via scripts | Via scripts | Via scripts |
| BuildKit compat | None | Partial | Full (BuildKit) | None |

---

## Strategic Analysis for Interview

### "Why can't you just use Docker in Kubernetes?" (Security)

Mounting `/var/run/docker.sock` in a pod gives that pod node-level root privileges. The Docker
daemon runs as root on the host — any process with socket access can create, modify, or delete
containers on the node. This bypasses all Kubernetes RBAC and namespace isolation. Privileged
containers (required for DinD) are similarly dangerous and often blocked by admission controllers.

### "How does Kaniko detect filesystem changes without overlayfs?" (Architecture)

Kaniko uses [`ptrace`](../articles/12-seccomp.md#ptrace) to intercept filesystem-modifying syscalls (`open`, `creat`, `unlink`,
`rename`, `mkdir`, `rmdir`) during a `RUN` instruction. After the command completes, it has a
precise list of changed files. It then creates a tar archive of those files — this is the new
layer. No kernel union filesystem is required, which is why Kaniko runs without privileges.

### "What is the main performance bottleneck in Kaniko?" (Performance)

The [ptrace](../articles/12-seccomp.md#ptrace)-based change detection. Every filesystem-modifying syscall from the build process and
its children is intercepted and evaluated by Kaniko's tracer process. For `RUN` instructions
that touch thousands of files (e.g., `npm install`, `pip install`, `apt-get install`), this
syscall interception overhead dominates build time. BuildKit and overlayfs-based builders compute
the diff in O(1) time by comparing layer snapshots at the VFS level.

### "When would you pick Kaniko over BuildKit?" (Decision)

Kaniko is the right choice when building images inside a Kubernetes cluster and the cluster's
security policy prohibits privileged containers, Docker socket mounts, or persistent daemons.
BuildKit is better when you have Docker socket access, need speed, or rely on BuildKit-exclusive
features like cache mounts, SSH forwarding, or parallel multi-stage execution.

### "How does Kaniko caching work?" (Caching)

Kaniko uses `--cache=true` with an optional `--cache-repo` to store built layers in a container
registry. Before executing each Dockerfile instruction, Kaniko queries the registry for a layer
matching the cache key (base image digest + instruction text + context checksum). On hit, it
downloads the layer instead of re-executing. This is slower than BuildKit's local content-hash
cache because every check requires a network round trip to the registry.

### "What alternatives exist for daemonless image building?" (Ecosystem)

Buildah (Red Hat) uses overlayfs in a user namespace and supports cache mounts — a strong middle
ground between Kaniko's security and BuildKit's performance. img wraps BuildKit in a temporary
container (still needs privileges). Makisu (Uber) uses overlayfs with content-hash caching but
is less actively maintained.

### Cross-References

- [Docker Architecture](../articles/30-docker-architecture.md) — why the Docker daemon model
  requires privileged access and socket-based communication.
- [BuildKit Internals](../articles/32-buildkit-internals.md) — BuildKit's DAG execution,
  content-addressed caching, cache mounts, and secret handling.
- [How Docker Builds Images](../articles/33-how-docker-builds-images.md) — the legacy builder
  and BuildKit pipelines that Kaniko replaces.
- [Non-Root Execution](../articles/10-non-root-execution.md) — user namespaces and running
  containers without root, relevant to rootless BuildKit and Buildah.
- [Seccomp](../articles/12-seccomp.md) — how syscall filtering interacts with ptrace-based
  builders like Kaniko.
- [Pod Security Standards](../articles/17-pod-security-standards.md) — Kubernetes policies that
  restrict privileged containers, motivating Kaniko adoption.
