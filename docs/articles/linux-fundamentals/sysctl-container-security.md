---
title: "sysctl: Kernel Parameter Tuning in Containers"
section: "Linux Fundamentals"
order: 38
---

# sysctl: Kernel Parameter Tuning in Containers

## What Is sysctl?

`sysctl` is the Linux kernel's runtime parameter interface. It exposes kernel tunables — network stack behavior, memory management, kernel limits — as files under `/proc/sys/`. Reading a file queries the current value; writing to it changes kernel behavior at runtime.

```bash
# Read the current value
sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 0

# Write a new value (requires privileges)
sysctl -w net.ipv4.ip_forward=1
```

The filesystem path maps to the dotted parameter name: `net/ipv4/ip_forward` becomes `net.ipv4.ip_forward`.

## sysctl in Containers

In a container, `/proc/sys/` is **bind-mounted read-only** by default (the OCI `readonlyPaths` list includes `/proc/sys`). The container can read kernel parameters but cannot modify them. This is enforced by runc at container creation time:

```json
"readonlyPaths": [
  "/proc/sys",
  "/proc/bus",
  "/proc/fs",
  "/proc/irq"
]
```

If a container does need to set a kernel parameter, two conditions must be met:

1. **Write access to `/proc/sys/`** — the `readonlyPaths` restriction must be lifted
2. **Capability to write** — writing to `/proc/sys/` requires `CAP_SYS_ADMIN`

## Safe vs Unsafe Sysctls

Sysctls fall into two categories based on whether they are **namespaced** — isolated per kernel namespace.

### Namespaced (Safe) Sysctls

These are isolated by a kernel namespace. Setting them affects only the container's namespace, not the host or other containers:

| Namespace | Example Sysctls | Effect |
|-----------|-----------------|--------|
| **net** (network namespace) | `net.ipv4.ip_forward`, `net.ipv4.conf.*`, `net.core.somaxconn` | Network stack behavior within the container's netns |
| **ipc** (IPC namespace) | `kernel.msgmax`, `kernel.msgmnb`, `kernel.msgmni`, `kernel.sem`, `kernel.shmall`, `kernel.shmmax`, `kernel.shmmni` | IPC limits — namespaced since Linux 4.18+ |

The `net.*` sysctls are the most commonly used. They are safe because the network namespace provides full isolation — changes cannot leak to the host or other containers.

```bash
# Safe: affects only this container's network namespace
sysctl -w net.ipv4.tcp_tw_reuse=1
sysctl -w net.core.somaxconn=1024
sysctl -w net.ipv4.ip_local_port_range="1024 65535"
```

### Non-Namespaced (Unsafe) Sysctls

These are **not** isolated by any namespace. Setting them affects the host kernel globally:

| Sysctl | Risk |
|--------|------|
| `fs.inotify.max_user_watches` | Inotify limit — affects the host's inotify capacity |
| `vm.overcommit_memory`, `vm.swappiness` | Memory management — affects host's virtual memory behavior |

Setting an unsafe sysctl breaks namespace isolation. A compromised container could:
- Exhaust host-wide inotify capacity (`fs.inotify.max_user_watches` → denial of service)
- Trigger OOM behavior across the entire host (`vm.overcommit_memory`)
- Cause kernel instability through shared memory exhaustion

### How the Kernel Enforces Namespace Isolation

The kernel tracks which sysctls are namespaced via internal `ctl_table` structures. Each registered sysctl carries a flag indicating whether it supports namespace isolation. When a kernel namespace is created (e.g., `clone(CLONE_NEWNET)`), the kernel copies the initial values into the namespace's sysctl table. Subsequent writes inside that namespace modify only the namespace-local copy.

For non-namespaced sysctls, there is only one copy — the host's. A write from any namespace modifies the single global value.

## Setting Sysctls in Docker

Docker's `--sysctl` flag lets you set namespaced sysctls at container creation:

```bash
# Set a net sysctl (safe, namespaced)
docker run --sysctl net.ipv4.ip_forward=1 alpine

# Set a kernel sysctl (unsafe, global) — requires special permission
docker run --sysctl kernel.msgmax=65536 alpine
# Error: --sysctl is allowed only for namespaced sysctls by default
```

Docker enforces a whitelist: only `net.*` sysctls can be set with `--sysctl` by default. To set non-namespaced sysctls, you must pass `--privileged` or configure `--security-opt`:

```bash
# Only works with --privileged
docker run --privileged --sysctl kernel.msgmax=65536 alpine
```

### Docker Default Allowed Sysctls

| Pattern | Namespaced | Allowed by Default |
|---------|------------|--------------------|
| `net.*` | Yes (net ns) | Yes |
| `kernel.msg*` | Yes (ipc ns, Linux 4.18+) | No (Docker whitelist predates this) |
| `kernel.sem` | Yes (ipc ns, Linux 4.18+) | No |
| `kernel.shm*` | Yes (ipc ns, Linux 4.18+) | No |
| `fs.inotify.*` | No | No |
| `vm.*` | No | No |

## Setting Sysctls in Kubernetes

Kubernetes exposes sysctls through the `PodSecurityContext.sysctls` field:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: sysctl-demo
spec:
  securityContext:
    sysctls:
    - name: net.ipv4.tcp_tw_reuse
      value: "1"
    - name: net.core.somaxconn
      value: "1024"
  containers:
  - name: app
    image: nginx
```

### Safe vs Unsafe Sysctl Classes

Kubernetes classifies sysctls as **safe** (namespaced, isolated) or **unsafe** (non-namespaced, global):

| Class | Definition | Examples | Allowed by Default |
|-------|------------|----------|--------------------|
| **Safe** | Namespaced in a kernel namespace the container already has | `net.*`, `kernel.msg*` (ipc ns), `kernel.sem` (ipc ns) | Yes |
| **Unsafe** | Not namespaced, or namespaced in a namespace the container does not have by default | `vm.*`, `fs.inotify.*`, `kernel.core_pattern` | No — must be explicitly enabled |

Kubernetes's safe list (as of v1.31):

```
kernel.shm_rmid_forced
net.ipv4.ip_local_port_range
net.ipv4.ip_unprivileged_port_start
net.ipv4.tcp_syncookies
net.ipv4.ping_group_range
net.ipv4.ip_forward
net.ipv4.tcp_keepalive_time
net.core.somaxconn
```

Everything else is unsafe and requires a cluster-level enable.

### Enabling Unsafe Sysctls

To use unsafe sysctls, a cluster administrator must enable them on each node:

```bash
# kubelet flag to allow specific unsafe sysctls
--allowed-unsafe-sysctls=kernel.msgmax,kernel.msgmnb
```

Or in kubelet config:

```yaml
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
allowedUnsafeSysctls:
  - "kernel.msgmax"
  - "kernel.msgmnb"
```

Once enabled at the node level, they can be used in Pod specs:

```yaml
spec:
  securityContext:
    sysctls:
    - name: kernel.msgmax
      value: "65536"
    - name: kernel.msgmnb
      value: "65536"
```

### Risks of Unsafe Sysctls in Kubernetes

1. **Node-wide impact**: Setting `vm.overcommit_memory=1` on one pod affects all pods on that node.
2. **Denial of service**: `fs.inotify.max_user_watches=1` can starve other workloads of inotify watches.
3. **Resource exhaustion**: Lowering `kernel.shmall` can crash applications relying on shared memory.
4. **Node compromise**: Some sysctls (`kernel.core_pattern`, `kernel.kptr_restrict`) can leak kernel information or redirect crash dumps.

## Capabilities Required for Sysctl Operations

Setting sysctls requires `CAP_SYS_ADMIN` — the most powerful Linux capability. This is a problem because `CAP_SYS_ADMIN` grants nearly unrestricted root access (mount, namespace manipulation, kernel module loading).

| Operation | Capability Required | Notes |
|-----------|-------------------|-------|
| Read any sysctl | None (file is world-readable) | Default `/proc/sys/` permissions |
| Write to `/proc/sys/` | `CAP_SYS_ADMIN` | The kernel checks for `CAP_SYS_ADMIN` in `proc_sys_permission()` |
| Use `sysctl()` system call | `CAP_SYS_ADMIN` | The legacy syscall interface (deprecated) |

```bash
# Even with --sysctl, Docker internally grants CAP_SYS_ADMIN
docker run --sysctl net.ipv4.ip_forward=1 alpine
# The container receives CAP_SYS_ADMIN implicitly
```

This means **any container granted sysctl write access is effectively running with `CAP_SYS_ADMIN`**. The compromise is that sysctl access is a subset of `CAP_SYS_ADMIN`, but the kernel does not provide finer granularity.

## Seccomp and Sysctl

The `sysctl()` system call (legacy interface, rarely used) is blocked in Docker's default seccomp profile:

```json
{
  "names": ["sysctl"],
  "action": "SCMP_ACT_ERRNO"
}
```

The modern interface — writing to `/proc/sys/` files — uses `open()`, `write()`, and `close()`, which are all allowed. Blocking `/proc/sys` writes requires the read-only bind mount (OCI `readonlyPaths`), not seccomp.

## Pod Security Standards

The Kubernetes **Restricted** Pod Security Standard does not explicitly mention sysctls. However, the underlying requirements indirectly restrict them:

| PSS Profile | Sysctl Restriction |
|-------------|-------------------|
| **Privileged** | No restrictions |
| **Baseline** | Only safe sysctls |
| **Restricted** | Only safe sysctls + additional hardening |

Because setting unsafe sysctls requires effectively `CAP_SYS_ADMIN`, and CAP_SYS_ADMIN is dropped by the Restricted profile's requirement to drop ALL capabilities, unsafe sysctls are implicitly blocked in Restricted namespaces.

```yaml
# Restricted-compatible: safe sysctls only
spec:
  securityContext:
    sysctls:
    - name: net.ipv4.tcp_tw_reuse
      value: "1"
    - name: net.core.somaxconn
      value: "1024"
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    securityContext:
      capabilities:
        drop: ["ALL"]
```

## Practical Verification

```bash
# Check which sysctls are namespaced
docker run --rm alpine cat /proc/self/ns/net
# net:[4026531993]

# Set a safe sysctl
docker run --rm --sysctl net.ipv4.ip_forward=1 alpine sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 1

# Verify isolation: second container sees default
docker run --rm alpine sysctl net.ipv4.ip_forward
# net.ipv4.ip_forward = 0

# Attempt an unsafe sysctl (fails without --privileged)
docker run --rm --sysctl kernel.hostname=test alpine
# Error: --sysctl is allowed only for namespaced sysctls

# Check /proc/sys is read-only in a default container
docker run --rm alpine touch /proc/sys/test
# touch: /proc/sys/test: Read-only file system
```

## Common Use Cases

### 1. Enabling IP Forwarding for a Container Router

```bash
docker run --cap-add=NET_ADMIN --sysctl net.ipv4.ip_forward=1 my-router
```

### 2. Increasing Connection Backlog

```yaml
spec:
  securityContext:
    sysctls:
    - name: net.core.somaxconn
      value: "4096"
    - name: net.ipv4.tcp_max_syn_backlog
      value: "1024"
```

### 3. Adjusting Keepalive for Load Balancers

```yaml
spec:
  securityContext:
    sysctls:
    - name: net.ipv4.tcp_keepalive_time
      value: "300"
    - name: net.ipv4.tcp_keepalive_intvl
      value: "30"
    - name: net.ipv4.tcp_keepalive_probes
      value: "5"
```

## Security Recommendations

1. **Never set unsafe sysctls in production** unless you fully understand the host-wide impact. Prefer redesigning the architecture to avoid the need.
2. **Audit all `sysctls` fields in Helm charts and manifests** — any unsafe sysctl is a red flag.
3. **Prefer `net.*` sysctls only** — they are safe (namespaced) and sufficient for most use cases.
4. **Avoid `--privileged` for sysctl access** — if you must set an unsafe sysctl, use `--sysctl` with the specific parameter rather than `--privileged`.
5. **Use admission control** to block unsafe sysctls cluster-wide.
6. **Remember that sysctl access implies `CAP_SYS_ADMIN`** — treat any container with sysctl write access as high-risk.

## Interview Tips

Understand that sysctl is a namespace isolation boundary test. The interviewer may ask: "How would you configure a container to act as a router?" The answer involves `--sysctl net.ipv4.ip_forward=1` and `--cap-add=NET_ADMIN`. Be ready to explain why some sysctls are unsafe (not namespaced) while others are safe (namespaced by network namespace). Know that setting sysctls requires `CAP_SYS_ADMIN`, which is effectively root. Discuss the trade-off between granting `CAP_SYS_ADMIN` for a single sysctl vs the principle of least privilege. Understand that the Kubernetes safe sysctl list is a whitelist of namespaced parameters that have been verified not to break isolation.

## Cross-References

- [/proc and Container Isolation](proc-container-isolation.md) — how `/proc/sys/` is made read-only via `readonlyPaths`
- [Linux Capabilities](../container-image-hardening/linux-capabilities.md) — `CAP_SYS_ADMIN` and the privilege model
- [Seccomp](../container-image-hardening/seccomp.md) — legacy `sysctl()` syscall filtering
- [SecurityContext vs PodSecurityContext](../kubernetes-security/securitycontext-vs-podsecuritycontext.md) — the `sysctls` field in PodSecurityContext
- [Adapting Upstream Helm Charts](../kubernetes-security/adapting-upstream-helm-charts.md) — init containers that set sysctls
- [Pod Security Standards](../kubernetes-security/pod-security-standards.md) — implicit sysctl restrictions via capability dropping
