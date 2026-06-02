---
title: "Docker Architecture"
section: "Docker"
order: 30
---

# Docker Architecture

## Overview

Docker is a layered stack of cooperating components: the CLI, the daemon, container runtimes, and
kernel primitives. This article breaks down each layer — `docker` CLI, `dockerd`, `containerd`,
`containerd-shim`, and `runc` — and explains the OCI specifications that make the stack portable.

---

## Client-Server Model

The `docker` CLI communicates with `dockerd` over a REST API. By default, the daemon listens on a
local Unix socket at `/var/run/docker.sock`. The socket is owned by `root`; users in the `docker`
group can issue any API call, so group membership is effectively root access.

```bash
# The CLI resolves the socket path automatically
docker ps

# Equivalent curl
curl --unix-socket /var/run/docker.sock \
  http://localhost/v1.46/containers/json
```

For remote access, the daemon can listen on TCP — port `2376` for TLS, `2375` for unencrypted.
Production deployments must enable TLS:

```bash
dockerd --tlsverify \
  --tlscacert=ca.pem --tlscert=server-cert.pem --tlskey=server-key.pem \
  -H=0.0.0.0:2376
```

The API is versioned. The daemon supports multiple versions simultaneously:

```bash
DOCKER_API_VERSION=1.39 docker ps
```

---

## dockerd

`dockerd` is the persistent daemon managing images, containers, networks, and volumes.

### Responsibilities

1. **API server**: Listens on the configured socket, parses REST requests, dispatches to handlers.
2. **Image management**: Pull, store, tag, delete images. Delegates to containerd.
3. **Container lifecycle**: Create, start, stop, remove containers. Delegates to containerd.
4. **Volume management**: Create and mount volumes via volume drivers (local, NFS, cloud plugins).
5. **Network management**: Create networks, manage DNS and port publishing.
6. **Build engine**: Run `docker build` via BuildKit (since Docker 23.0).

### Configuration

The daemon reads `/etc/docker/daemon.json`:

```json
{
  "storage-driver": "overlay2",
  "exec-opts": ["native.cgroupdriver=systemd"],
  "live-restore": true,
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

### Image Storage

Data lives under `/var/lib/docker/`:

```
/var/lib/docker/
├── containers/   # Container metadata
├── image/        # Image metadata
├── overlay2/     # Layer data
├── volumes/      # Volume data
├── network/      # Network state
└── plugins/      # Plugin data
```

With `overlay2`, layers are stored as directories under `overlay2/`, each identified by its DiffID
(sha256 of the uncompressed layer tarball).

---

## containerd

containerd is the industry-standard container runtime Docker uses under the hood. Originally
extracted from Docker's internals and donated to the CNCF, it graduated as an incubating project in
2019. Docker, Kubernetes (via CRI), Nomad, and others embed it.

### Subsystems

containerd runs as a daemon exposing a gRPC API on `/run/containerd/containerd.sock`:

- **Content store**: Blob storage addressed by digest (content-addressable).
- **Snapshotter**: Filesystem snapshots for container rootfs (overlayfs, native, devmapper).
- **Metadata store**: BoltDB-backed image and container metadata.
- **Image service**: Pull, push, authenticate, traverse image indexes.
- **Container service**: Create, start, stop, delete containers.
- **Task service**: Manage running processes — each task has a PID and a corresponding shim.

### containerd vs. Docker

| Concern | Docker | containerd |
|---------|--------|------------|
| API style | REST (HTTP) | gRPC (protobuf) |
| Image building | Yes (BuildKit) | No |
| Volume / Network mgmt | Yes | No |
| CLI | `docker` | `ctr`, `nerdctl` |
| Kubernetes | Via dockershim (removed 1.24) | Directly via CRI plugin |

```bash
ctr images list
ctr images pull docker.io/library/alpine:latest
ctr run docker.io/library/alpine:latest my-alpine sh
```

---

## containerd-shim

`containerd-shim` is a per-container process bridging containerd and the OCI runtime. It solves a
critical problem: **container processes must survive daemon restarts**. If containerd crashes, the
shim keeps stdio open and tracks exit status. When containerd comes back, it reconnects.

```
dockerd → containerd → containerd-shim (per container) → runc → container process
```

Each container gets its own shim. A crash in one shim does not affect others. Shim variants include
`containerd-shim-runc-v1`, `containerd-shim-runc-v2` (current standard), and custom shims for
Kata Containers or gVisor.

```bash
ps aux | grep containerd-shim
# /usr/bin/containerd-shim-runc-v2
#   -namespace moby -id abc123... -address /run/containerd/containerd.sock
```

---

## runc

`runc` is the OCI-compliant low-level runtime that creates the container — namespaces, cgroups,
mounts, seccomp, and exec.

Given a bundle with `config.json` and `rootfs/`:

```bash
runc run my-container
```

### Startup Sequence

1. Read `config.json`.
2. Mount rootfs (pivot_root or chroot).
3. Clone namespaces (`CLONE_NEW*` flags).
4. Write PID to cgroup files.
5. Mount /proc, /sys, /dev.
6. Load seccomp BPF filter.
7. Drop capabilities (`cap_set_proc`).
8. Write UID/GID mappings for user namespaces.
9. `execve` the container process.

#### chroot and pivot_root

`chroot` changes the apparent root directory for a process and its children. A process
chrooted to `/some/root` sees that path as `/` and cannot access files outside it. It was the
earliest Unix isolation primitive and a precursor to containers (the first "jail" systems in
1999 used chroot alone).

In containers, runc uses `pivot_root` (preferred) or `chroot` (fallback) to mount the
container's root filesystem:

- **pivot_root**: Moves the old root mount to a separate directory (`put_old`), giving the
  container its own mount namespace root. The host root is still mounted but invisible to the
  container process. Preferred because the old root remains accessible from other
  mount namespaces and a correct `pivot_root` ensures the container can't navigate back to the
  host filesystem through the mount table.
- **chroot**: Simpler, used when pivot_root is unavailable (e.g., containers without a mount
  namespace, or when the rootfs isn't a mount point). A chroot can be escaped by a privileged
  process that can `mkdir foo; chroot foo; cd ..` — which is why runc always combines chroot
  with a dedicated mount namespace and drops `CAP_SYS_CHROOT` in the container.

The OCI spec requires runtimes to call either `pivot_root` or `chroot` on the rootfs. This is
step 2 in the startup sequence above.

### Kernel Features

#### Namespaces

| Namespace | Isolates | Kernel |
|-----------|----------|--------|
| `pid` | Process IDs | 3.8+ |
| `net` | Network stack | 2.6.29+ |
| `mnt` | Mount points | 2.4.19+ |
| `user` | UID/GID mappings | 3.8+ |
| `uts` | Hostname | 2.6.19+ |
| `ipc` | System V IPC | 2.6.19+ |
| `cgroup` | Cgroup root view | 4.6+ |
| `time` | System time | 5.6+ |

User namespaces are covered in [Non-Root Execution](../articles/10-non-root-execution.md).

#### cgroups

Limit CPU, memory, I/O, and PIDs. cgroups v1 uses separate hierarchies under `/sys/fs/cgroup/`.
cgroups v2 uses a unified hierarchy (default since systemd 242+).

```json
"linux": {
  "resources": {
    "memory": { "limit": 536870912, "swap": 1073741824 },
    "cpu": { "shares": 512, "quota": 100000, "cpus": "0-3" },
    "pids": { "limit": 100 }
  }
}
```

#### Seccomp, Capabilities, MAC

- **Seccomp**: Filters syscalls. Blocks ~50 dangerous, allows ~300+. See
  [Seccomp](../articles/12-seccomp.md).
- **Capabilities**: Divides root privileges into discrete units. Dropped by default. See
  [Linux Capabilities](../articles/11-linux-capabilities.md).
- **MAC**: SELinux and AppArmor profiles. See
  [AppArmor / SELinux](../articles/13-apparmor-selinux.md).

### History

runc was created by Docker Inc. and contributed to the Open Container Initiative (OCI) in
2015. It was extracted from Docker's internal **libcontainer** library, which had been the
low-level runtime embedded in the Docker daemon since 2013. The extraction served three
goals:

1. **Standardization**: Before the OCI, every container runtime had its own image format,
   configuration format, and lifecycle. A shared spec made tools interchangeable.
2. **Separation of concerns**: The daemon should not embed a runtime — it should delegate to
   a standalone binary governed by a public specification.
3. **Ecosystem growth**: Other tools (Podman, CRI-O, Kubernetes) needed a runtime they could
   use without importing Docker internals.

Key milestones:

| Date | Event |
|------|-------|
| June 2015 | Docker donates libcontainer to the OCI (Linux Foundation) |
| July 2015 | runc v0.1.0 released |
| April 2016 | Docker 1.11 swaps internal runtime for runc, introduces containerd |
| 2017 | runc becomes the default runtime for Kubernetes via CRI-O and containerd |
| Present | Most widely deployed OCI runtime; ~100 community contributors |

runc is a single Go binary — no daemon, no persistent state:

```bash
which runc
# /usr/bin/runc

runc --version
# runc version 1.1.12
# spec: 1.1.0+dev
```

### Architecture

runc is **not a daemon**. It is a one-shot CLI tool that exits after the container is
running. The containerd-shim is the persistent parent that keeps stdio alive and reaps the
child.

#### Fork/Exec Model

runc uses a two-phase fork/exec design:

```
Phase 1 — Setup (runc run)

    containerd-shim
         │
         │ exec runc run <id>
         ▼
    runc (parent) ─── reads config.json, parses OCI bundle
         │
         │ fork + unshare(CLONE_NEW*)
         ▼
    runc init (child) ─── enters new namespaces
         │
         ├── writes PID to cgroup files
         ├── mounts /proc, /sys, /dev
         ├── loads seccomp BPF filter
         ├── drops capabilities (cap_set_proc)
         ├── writes UID/GID mappings (user ns)
         └── pivot_root → chdir to new root

Phase 2 — Handoff

    runc init (child) ─── execve(container entrypoint)
         │
         ▼
    Container PID 1    ─── reparented to containerd-shim

    runc (parent) ─── writes PID to shim, exits
```

Step-by-step:

1. `runc run` is invoked by the shim with the container ID and bundle path.
2. **runc (parent)** reads `config.json`, validates the spec, opens synchronization pipes,
   and forks with `CLONE_NEW*` flags into the new namespaces.
3. **runc init (child)** is now inside partially-isolated namespaces. It continues setup:
   writes the PID to cgroupfs, mounts `/proc`, `/sys`, `/dev`, loads the seccomp BPF
   filter via `seccomp(SECCOMP_SET_MODE_FILTER)`, drops capabilities, writes user
   namespace mappings, and calls `pivot_root` (or `chroot`) into the container rootfs.
4. **Init** calls `execve()` on `process.args[0]` (e.g., `/bin/sh`). This replaces the
   runc init process with the container's PID 1.
5. **runc (parent)** writes the container PID to the shim's tracking, then exits. The
   container process is reparented to the shim.

#### Key Consequence: runc Exits

Because runc exits after setup:

- **runc can be updated** independently of running containers. A new `runc` binary takes
  effect on the next `runc run` or `runc exec`.
- **Setup is atomic**. If runc crashes during setup, the container is destroyed — there is
  no half-initialized container.
- **After execve, runc is out of the critical path**. Only the shim stays alive. This is
  why `runc exec` works: a new runc instance joins the container's existing namespaces,
  enters them, and execs the command.

### OCI Bundle

An OCI bundle is the filesystem layout runc expects:

```
my-bundle/
├── config.json      # OCI Runtime Spec configuration
└── rootfs/          # Container root filesystem (e.g., extracted image layer)
```

Generate a default `config.json` with:

```bash
runc spec
```

A minimal `config.json` with security-hardened defaults:

```json
{
  "ociVersion": "1.1.0",
  "process": {
    "user": { "uid": 0 },
    "args": ["/bin/sh"],
    "env": ["PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"],
    "cwd": "/",
    "noNewPrivileges": true,
    "capabilities": {
      "bounding": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
      "effective": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"],
      "permitted": ["CAP_AUDIT_WRITE", "CAP_KILL", "CAP_NET_BIND_SERVICE"]
    }
  },
  "root": { "path": "rootfs", "readonly": true },
  "hostname": "container",
  "mounts": [
    { "destination": "/proc", "type": "proc", "source": "proc" },
    { "destination": "/dev", "type": "tmpfs", "source": "tmpfs",
      "options": ["nosuid","strictatime","mode=755","size=65536k"] }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid" }, { "type": "network" }, { "type": "mount" },
      { "type": "ipc" }, { "type": "uts" }, { "type": "cgroup" }
    ],
    "resources": {
      "memory": { "limit": 536870912 },
      "cpu": { "shares": 512 }
    },
    "seccomp": {
      "defaultAction": "SCMP_ACT_ERRNO",
      "architectures": ["SCMP_ARCH_X86_64"],
      "syscalls": [
        { "names": ["accept", "access", "...rest of allowlist..."],
          "action": "SCMP_ACT_ALLOW" }
      ]
    }
  }
}
```

Key fields from a security perspective:

- **`root.readonly: true`** — Makes the rootfs immutable. The container must use tmpfs or
  a volume mount for writes. Default in Kubernetes Pods.
- **`process.noNewPrivileges: true`** — Prevents the container process from gaining
  privileges via setuid binaries or `ambient` capabilities.
- **`process.capabilities`** — The default `bounding` set in `runc spec` drops ~16 of ~41
  capabilities. The container process has no way to re-acquire dropped caps.
- **`linux.namespaces`** — Each entry requests a new kernel namespace. User namespaces are
  not created by default in rootful runc (requires explicit `"type": "user"` and
  UID/GID mappings).

### Security Model

runc's security model is driven by what it must do: **create containers using kernel
primitives that require privilege**.

#### Why runc Needs Root

| Operation | Required Linux capability |
|-----------|--------------------------|
| `unshare(CLONE_NEWNS)` / `clone(CLONE_NEW*)` | `CAP_SYS_ADMIN` |
| `mount()` syscall | `CAP_SYS_ADMIN` |
| `pivot_root()` | `CAP_SYS_ADMIN` |
| Write PID to cgroup files | Root or delegated cgroup access |
| `seccomp(SECCOMP_SET_MODE_FILTER)` | `CAP_SYS_ADMIN` or `prctl(PR_SET_NO_NEW_PRIVS)` |
| `cap_set_proc()` to drop capabilities | `CAP_SETPCAP`, `CAP_SETUID`, `CAP_SETGID` |
| `sethostname()` (UTS namespace) | `CAP_SYS_ADMIN` |

Rootless mode (via `XDG_RUNTIME_DIR`, `--rootless`) mitigates this by running inside a
user namespace: the daemon's UID is mapped to root inside the container, but the host sees
an unprivileged user. Trade-offs:

| Feature | Rootful | Rootless |
|---------|---------|----------|
| Namespace creation | Direct syscalls | User namespace + `newuidmap` |
| Filesystem | overlay2 | fuse-overlayfs (slower) |
| Network | Kernel (iptables) | slirp4netns (~10-20% slower) |
| Cgroups | Full cgroup v1/v2 | cgroup v2 only, limited delegation |
| Privileged ports | Works directly | Needs `setcap` CAP_NET_BIND_SERVICE |

#### Attack Surface

runc's attack surface is concentrated in **container creation and exec**. After setup, runc
has exited and is no longer in the process chain:

1. **config.json parsing**: Malicious or malformed `config.json` from an untrusted image
   could trigger parsing bugs in the Go JSON decoder or in runc's spec validation.
2. **Filesystem setup**: runc mounts procfs, sysfs, devtmpfs, and the rootfs inside the
   namespace. A malicious rootfs with crafted symlinks or device nodes could confuse mount
   order.
3. **Seccomp loading**: The BPF filter is loaded before `execve`. If the kernel doesn't
   support a requested seccomp action, runc must fail safely rather than silently skipping
   the filter.
4. **File descriptor leaks**: The OCI spec requires runc to pass specific FDs into the
   container. Any host-side FD not `O_CLOEXEC` before `execve` becomes accessible to the
   container process — the root cause of CVE-2024-21626.
5. **`/proc/self/exe` race**: During setup, runc opens its own binary to read or write
   state. If a malicious process inside the container can ptrace the runc init process
   (which shares the container's PID namespace during setup, before `execve`), it can
   overwrite the runc binary on the host — the root cause of CVE-2019-5736.

### CVEs

runc has had several critical vulnerabilities. Understanding them demonstrates depth of
container security knowledge.

#### CVE-2019-5736 (runc container escape)

| Field | Value |
|-------|-------|
| **Date** | February 2019 |
| **CVSS** | 7.2 (HIGH) |
| **Root cause** | During setup, runc opens `/proc/self/exe` from inside the container's namespaces (before `execve`). A malicious process already running in the container can ptrace the runc init process (they share the same PID namespace) and overwrite `/proc/self/exe` with arbitrary code. When runc exits, the host executes the attacker's payload as root. |
| **Impact** | Full host root compromise from any container. |
| **Fix** | runc 1.0-rc6. The binary FD is opened from the **host** mount namespace using `O_CLOEXEC` before entering the container. The FD is never exposed to the container. |
| **Lesson** | The vulnerability exploited the time window during setup when runc init was inside container namespaces but still running as runc (before `execve`). This is a fundamental tension in the fork/exec model. |

```go
// Vulnerable pattern (pre-1.0-rc6):
// runc enters namespaces first, then opens /proc/self/exe
f, _ := os.Open("/proc/self/exe")
// Container process can ptrace this and replace the file

// Fixed pattern (1.0-rc6+):
// Open /proc/self/exe BEFORE entering namespaces, with O_CLOEXEC
f, _ := os.OpenFile("/proc/self/exe", os.O_RDONLY|syscall.O_CLOEXEC, 0)
// Enter namespaces after the FD is already open and locked
```

#### CVE-2024-21626 (runc leaked file descriptors)

| Field | Value |
|-------|-------|
| **Date** | January 2024 |
| **CVSS** | 8.6 (HIGH) |
| **Root cause** | runc leaked a host-side directory FD into the container. The container process could use `openat(leaked_fd, "../../../etc/passwd")` to traverse up to any host path. |
| **Impact** | Container escape via path traversal on the leaked FD. |
| **Fix** | runc 1.1.12. All internal FDs are set `O_CLOEXEC` before `execve`. |
| **Lesson** | File descriptor hygiene is the single most important coding practice for OCI runtimes. Every FD not explicitly requested by `config.json` must be closed-on-exec. |

#### CVE-2022-29162 (runc exec symlink traversal)

| Field | Value |
|-------|-------|
| **Date** | May 2022 |
| **CVSS** | 6.2 (MEDIUM) |
| **Root cause** | `runc exec` followed symbolic links inside the container's cgroup mount when writing the PID, allowing a malicious container to escape by pointing the cgroup write at a host path. |
| **Impact** | Limited — required a specific cgroup configuration and a symlink inside the container. |
| **Fix** | runc 1.1.2. The cgroup path is resolved with `filepath.EvalSymlinks` before writing. |

#### Summary

| CVE | Year | CVSS | Type | Fixed in |
|-----|------|------|------|----------|
| CVE-2019-5736 | 2019 | 7.2 | Container escape (/proc/self/exe race) | runc 1.0-rc6 |
| CVE-2022-29162 | 2022 | 6.2 | Symlink traversal (runc exec) | runc 1.1.2 |
| CVE-2024-21626 | 2024 | 8.6 | Container escape (leaked FDs) | runc 1.1.12 |

### Alternatives

runc is the reference implementation but not the only OCI runtime:

| Runtime | Language | Key Feature | Default in |
|---------|----------|-------------|------------|
| **runc** | Go | Reference implementation, most battle-tested | Docker, containerd, CRI-O (default) |
| **crun** | C | ~50% faster startup, ~80% less memory | Podman, CRI-O (configurable) |
| **youki** | Rust | Memory-safe by language design | NixOS container manager |
| **gVisor** | Go | Userspace kernel — no direct host syscalls | GKE Sandbox (optional) |
| **Kata Containers** | Go/C | Lightweight VM per container (microVM) | OpenShift sandboxed containers |

#### crun

Written in C by Giuseppe Scrivano (Red Hat). Default runtime in Podman and CRI-O. Faster
than runc because no Go runtime initialization and direct C library calls for namespace
operations. Per-container memory: ~2-3 MB vs ~10-15 MB for runc.

```bash
# containerd can be configured to use crun
ctr run --runtime=io.containerd.crun.v1 ...
```

#### youki

Written in Rust. Memory safety guarantees eliminate use-after-free, buffer overflows, and
data races — the most common vulnerability classes in C and Go runtimes. Fully
OCI-compatible and passes the OCI runtime certification tests.

#### gVisor and Kata Containers

These are not direct runc replacements — they implement fundamentally different security
models:

- **gVisor**: Intercepts syscalls at the application level with a userspace kernel (the
  Sentry). The container process never makes a direct host syscall. ~85% syscall coverage.
  Performance overhead: 40-60% for CPU-bound workloads.
- **Kata Containers**: Runs each container in a lightweight VM (QEMU, Firecracker, or Cloud
  Hypervisor). Each container gets its own kernel. Strongest isolation. Performance
  overhead: ~10-20% for CPU-bound.

Both implement their own containerd shims (`containerd-shim-kata-v2`,
`containerd-shim-runsc-v1`) that present the standard OCI interface, allowing them to slot
into the same architecture as runc.

```
Security isolation:  Kata > gVisor > runc/crun/youki
Performance:         runc/crun > youki > gVisor > Kata
Compatibility:       runc/crun/youki > Kata > gVisor
```

---

## OCI Runtime Spec

The OCI Runtime Specification defines `config.json` structure and runtime behavior.

```json
{
  "ociVersion": "1.1.0",
  "process": {
    "user": { "uid": 0, "gid": 0 },
    "args": ["/bin/sh"],
    "env": ["PATH=/usr/local/sbin:..."],
    "cwd": "/",
    "noNewPrivileges": true
  },
  "root": { "path": "rootfs", "readonly": true },
  "mounts": [
    { "destination": "/proc", "type": "proc", "source": "proc" }
  ],
  "linux": {
    "namespaces": [
      { "type": "pid" }, { "type": "network" }, { "type": "mount" },
      { "type": "ipc" }, { "type": "uts" }, { "type": "cgroup" }
    ],
    "maskedPaths": [
      "/proc/kcore", "/proc/keys", "/proc/latency_stats",
      "/proc/timer_list", "/proc/sched_debug", "/sys/firmware"
    ],
    "readonlyPaths": [
      "/proc/bus", "/proc/fs", "/proc/irq", "/proc/sys"
    ]
  }
}
```

Key fields:

- **`process`**: Executable, args, env, cwd, capabilities, rlimits, security labels.
- **`root`**: Rootfs path and readonly flag.
- **`mounts`**: Filesystem mounts inside the container.
- **`linux.namespaces`**: Which kernel namespaces to create.
- **`linux.resources`**: cgroup resource limits.
- **`linux.seccomp`**: BPF syscall filter.
- **`linux.maskedPaths`**: Paths overmounted with empty tmpfs to hide kernel interfaces.
- **`linux.readonlyPaths`**: Paths bind-mounted read-only.

---

## OCI Image Spec

A container image is a **manifest**, a **config** JSON, and **layer tarballs**.

### Manifest

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.docker.distribution.manifest.v2+json",
  "config": { "digest": "sha256:b5b2b2c...", "size": 7023 },
  "layers": [
    {
      "mediaType": "application/vnd.docker.image.rootfs.diff.tar.gzip",
      "size": 32654,
      "digest": "sha256:e692418e..."
    }
  ]
}
```

### Config

```json
{
  "architecture": "amd64",
  "os": "linux",
  "rootfs": {
    "type": "layers",
    "diff_ids": ["sha256:e692418e...", "sha256:3c3a4604..."]
  },
  "config": {
    "User": "1000:1000",
    "ExposedPorts": { "8080/tcp": {} },
    "Env": ["PATH=/usr/local/bin:...", "APP_ENV=production"],
    "Entrypoint": ["/usr/bin/python3"],
    "Cmd": ["app.py"],
    "WorkingDir": "/app",
    "Labels": { "version": "1.0.0" }
  }
}
```

### Layers

Each layer is a tar archive — the filesystem diff between layers. Layers are content-addressable
(identified by digest), immutable, and shared across images.

```bash
docker history alpine:latest
# IMAGE          CREATED       CREATED BY                     SIZE
# 85f9be67a7e4   2 weeks ago   CMD ["/bin/sh"]                0B
# fa1e6bfe381c   2 weeks ago   ADD file:abc... in /           7.05MB
```

The `diff_ids` in the config are sha256 of **uncompressed** layers. The manifest digest references
the **compressed** blob. containerd verifies both at pull time.

### Multi-Architecture (Image Index)

The OCI Image Index maps a tag to platform-specific manifests:

```json
{
  "mediaType": "application/vnd.docker.distribution.manifest.list.v2+json",
  "manifests": [
    { "digest": "sha256:abc...", "platform": { "architecture": "amd64", "os": "linux" } },
    { "digest": "sha256:def...", "platform": { "architecture": "arm64", "os": "linux" } }
  ]
}
```

When pulling `python:3.12`, the client selects the manifest matching its `runtime.GOARCH` and
downloads only that image's layers.

---

## Docker vs. containerd vs. CRI

The Container Runtime Interface (CRI) is a Kubernetes gRPC protocol that lets kubelet use any
runtime. Before Kubernetes 1.24, kubelet translated CRI to Docker's API via `dockershim`:

```
kubelet → dockershim → dockerd → containerd → runc
```

After dockershim was removed:

```
kubelet → containerd (cri plugin) → runc
```

containerd has a built-in CRI plugin implementing the CRI gRPC service. **CRI-O** is an
alternative purpose-built for Kubernetes — it only speaks CRI, has no Docker-compatible API, and
is the default in OpenShift. Industry adoption: Kind, Minikube, GKE, EKS, AKS use containerd.

---

## Docker in Rootless Mode

Rootless mode runs `dockerd` and containers without root privileges (stable since Docker 20.10).

### Mechanisms

1. **User namespaces**: The daemon maps its UID to root inside the namespace; the host sees an
   unprivileged user.
2. **fuse-overlayfs**: Replaces `overlay2` (needs `mount()` syscalls) with a FUSE filesystem.
3. **slirp4netns**: Userspace network stack instead of kernel bridges and iptables.
4. **`dockerd-rootless.sh`**: Script to set up and start the rootless daemon.

```bash
dockerd-rootless-setuptool.sh install
dockerd-rootless.sh
```

### Limitations

| Feature | Rootful | Rootless |
|---------|---------|----------|
| Storage driver | overlay2 | fuse-overlayfs (slower) |
| Network performance | Native (iptables) | slirp4netns (~10-20% slower) |
| Privileged ports (<1024) | Works | Requires `setcap` or proxy |
| BPF networking | Works | Not available |
| Cgroups | Full | Limited (cgroup v2 only) |

---

## Container Startup Flow

When you run `docker run nginx:latest`:

```
1. docker CLI → POST /containers/create via /var/run/docker.sock
2. dockerd → resolve image, call containerd to pull
3. containerd → pull layers, unpack via snapshotter, launch shim
4. containerd-shim → open stdio pipes, write OCI bundle, invoke runc
5. runc → read config.json; clone namespaces; set cgroups; mount /proc/sys/dev;
   load seccomp; drop caps; write UID/GID mappings; pivot_root; execve
```

If `dockerd` crashes: containerd and the shim keep running, the nginx process continues serving
traffic, stdio is buffered by the shim. On restart, dockerd reconnects via containerd.

---

## Strategic Analysis for Interview

### "Explain the Docker architecture" (Standard)

Walk the call chain: CLI → REST → dockerd → containerd → shim → runc. The shim enables daemon
restarts without killing containers. End with kernel features: namespaces, cgroups, seccomp,
capabilities.

### "Why did Kubernetes remove dockershim?" (Architecture Depth)

Docker added an extra hop: dockershim → dockerd → containerd → runc. containerd's native CRI
plugin shortens this to containerd → runc, removing a translation layer and reducing latency.

### "What happens when the daemon crashes?" (Resilience)

The per-container shim holds stdio and tracks exit status. When the daemon restarts, it reconnects
via the shim's socket. The container never notices.

### "What's the difference between Docker and containerd?" (Scope)

Docker is a developer platform (build, volumes, networks, Compose, CLI). containerd is an embedded
runtime (pull, snapshot, lifecycle) — it does not build images, manage networks, or provide a
user-facing CLI.

### "How does rootless Docker work?" (Security)

User namespaces, fuse-overlayfs, and slirp4netns replace kernel-level features with userspace
equivalents — no `sudo` or setuid required.

### Cross-References

- [Non-Root Execution](../articles/10-non-root-execution.md)
- [Linux Capabilities](../articles/11-linux-capabilities.md)
- [Seccomp](../articles/12-seccomp.md)
- [AppArmor / SELinux](../articles/13-apparmor-selinux.md)
- [Docker Hardened Images](../articles/26-docker-hardened-images.md)
