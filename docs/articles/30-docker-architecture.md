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
