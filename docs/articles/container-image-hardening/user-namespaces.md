---
title: "User Namespaces in Containers"
section: "Container Image Hardening"
order: 7
---

# User Namespaces in Containers

## What Is a User Namespace?

A user namespace (`CLONE_NEWUSER`) is a Linux kernel feature that isolates UID and GID numbers. A process inside a user namespace can have UID 0 (root) inside the namespace while having a completely unprivileged UID (e.g., 100000) on the host.

This is the only namespace type that **can be created by an unprivileged process** — no `CAP_SYS_ADMIN` required. This makes user namespaces the foundation for rootless containers.

### UID/GID Mapping

When a user namespace is created, the kernel establishes a **UID/GID mapping** between IDs inside the namespace and IDs on the host. Two files control this:

- `/proc/PID/uid_map` — UID mapping (write once, then immutable)
- `/proc/PID/gid_map` — GID mapping (write once, then immutable)

The mapping format is:

```
<inside-ID> <outside-ID> <length>
```

For example:

```
0       100000      65536
65534   165534      1
```

This means:
- UIDs 0–65535 inside the namespace map to host UIDs 100000–165535
- UID 65534 (nobody) maps to host UID 165534

The container's root (UID 0) is actually UID 100000 on the host — no special privileges at the host level.

### Who Can Write the Mapping?

The kernel enforces strict rules on who can write UID/GID mappings:

| Scenario | Who Can Write uid_map |
|----------|----------------------|
| Process created user namespace itself | The process itself (once) |
| Another process with `CAP_SETUID` in the user namespace | With `newuidmap` setuid helper |
| Root on the host writing to a child namespace | Always allowed |

Once written, the mapping is **immutable** for the lifetime of the namespace. This prevents privilege escalation after the fact.

## /etc/subuid and /etc/subgid

These files delegate UID/GID ranges to unprivileged users so they can create user namespaces with valid mappings:

```
# /etc/subuid
artur:100000:65536
docker:165536:65536
```

Format: `<username>:<start-UID>:<count>`

The `shadow-utils` package provides `newuidmap` and `newgidmap` setuid helpers that read these files and write the corresponding `uid_map`/`gid_map` entries. When Docker's rootless mode creates a user namespace, it invokes `newuidmap` and `newgidmap` to set up the mapping.

```bash
# Inspect your delegated ranges
grep ^$(whoami): /etc/subuid

# These ranges are allocated by
# useradd --user-group --create-home artur
# which creates entries in /etc/subuid and /etc/subgid
```

## User Namespace as the "Parent" Namespace

User namespaces have a special property in the kernel: **every other namespace type is owned by a user namespace**. When a process creates a new mount, PID, or network namespace inside a user namespace, those namespaces are "owned" by that user namespace. The kernel uses the owning user namespace to determine what operations are allowed.

```
User namespace A (owns)
├── PID namespace (owned by A)
├── Mount namespace (owned by A)
├── Network namespace (owned by A)
└── IPC namespace (owned by A)
```

This ownership model means:

- **Capabilities in a user namespace grant power within the namespace**, but only over resources owned by that user namespace
- A process with `CAP_SYS_ADMIN` in its user namespace can do `mount()` — but only inside mount namespaces owned by that user namespace
- A process with `CAP_NET_ADMIN` can modify iptables rules — but only in network namespaces owned by that user namespace

This is how rootless Docker works: the daemon runs inside a user namespace, and all the namespaces it creates are owned by that user namespace. The kernel enforces that operations like `mount()` never touch host resources.

## Capabilities and User Namespaces

When a user namespace is created, the process **gains all capabilities** inside that namespace (but only for resources owned by the namespace). The kernel automatically adds all capabilities to the process's `Permitted`, `Effective`, `Inheritable`, and `Bounding` sets — but only within the scope of that user namespace.

This is the crucial distinction:

| Operation | Inside user namespace | Outside user namespace |
|-----------|----------------------|----------------------|
| `mount()` a tmpfs | ✅ Allowed (with `CAP_SYS_ADMIN`) | ❌ Blocked |
| `chown()` a file | ✅ Allowed | ❌ Blocked |
| `kill()` a process in same namespace | ✅ Allowed | ❌ Blocked |
| Load a kernel module | ✅ Capability exists but meaningless — kernel modules affect the host | ❌ Host kernel rejects it |
| `ptrace()` a host process | ✅ Technically in capability set | ❌ Kernel checks target is in same user namespace |

The key security property: **capabilities in a non-initial user namespace are "container-scoped."** They let you do privileged things inside your namespace boundaries, but those boundaries are enforced by the kernel.

## How Docker Uses User Namespaces

### Rootful Docker with --userns-remap

In rootful Docker, user namespaces are **disabled by default**. The container's UID 0 is the host's UID 0 — a container breakout is immediately root on the host.

Enable user namespaces with `daemon.json`:

```json
{
  "userns-remap": "default"
}
```

With `default`, Docker creates `/etc/subuid` and `/etc/subgid` entries for a `dockremap` user and maps each container's UID 0 to a unique host range (typically starting at 100000):

```
Container A: UID 0 → Host UID 100000
Container B: UID 0 → Host UID 165536
```

The `dockremap` user owns all container data under `/var/lib/docker/`. The kernel enforces that the container's processes cannot access files outside their mapped range.

### Why Off by Default?

User namespaces break common container workflows. Docker's design philosophy prioritized "it just works" over security-by-default:

| Problem | Root Cause |
|---------|-----------|
| **Volume permissions** | Container "root" is a high UID on the host; host files owned by the real user (UID 501) are inaccessible |
| **--privileged** | Privileged containers lose some capabilities in a non-initial user namespace — `CAP_SYS_ADMIN` is namespace-scoped |
| **Privileged ports (<1024)** | Needs explicit capability management |
| **Storage drivers** | `overlay2` needs `mount()` — allowed in user namespace but requires `fuse-overlayfs` for rootless |
| **Debugging** | `docker exec` and volume introspection become harder when UIDs are remapped |

Each breakage generates a support ticket. Docker chose compatibility. The industry is now converging on user namespaces as default, but it took a decade of kernel and tooling maturation.

### Rootless Docker

Rootless Docker (stable since 20.10) runs the **entire daemon** inside a user namespace. The host sees an unprivileged user (typically the user who installed Docker). Inside the user namespace, `dockerd` runs as root, creates containers, and manages networks — all within the namespace boundary.

```
Host (UID 1000) → User namespace → dockerd (UID 0 inside) → Container (UID 0 inside)
```

Mechanisms that enable rootless mode:

| Mechanism | Purpose |
|-----------|---------|
| **User namespace** | Map daemon UID → root inside namespace |
| **fuse-overlayfs** | Replace `overlay2` (needs `mount()` syscall) with FUSE — UID mapping in userspace |
| **slirp4netns** | Userspace network stack — NAT-based, no kernel iptables |
| **dockerd-rootless-setuptool.sh** | One-command setup; creates systemd user service |

```bash
dockerd-rootless-setuptool.sh install
docker context use rootless
docker run hello-world  # No sudo, no root
```

Trade-offs versus rootful Docker:

| Feature | Rootful | Rootless |
|---------|---------|----------|
| Storage driver | overlay2 | fuse-overlayfs (~20% slower) |
| Network | Kernel iptables | slirp4netns (~10-20% slower) |
| Cgroups | Full v1/v2 | cgroup v2 only, limited delegation |
| Privileged ports | Direct | Needs `setcap CAP_NET_BIND_SERVICE` |
| BPF (eBPF) | Full | Not available |

### Rootless Podman

Podman takes a different approach: **it uses user namespaces by default even in rootful mode**. Every Podman container runs inside a user namespace, regardless of whether the daemon is root or non-root.

```bash
# Rootful Podman still uses user namespaces
sudo podman run --rm alpine cat /proc/self/uid_map
# Shows a mapped range, not 0→0
```

This means Podman containers have stronger default isolation than rootful Docker containers.

## Kubernetes Per-Pod User Namespaces

Kubernetes supports per-pod user namespaces (alpha in 1.25, beta in 1.27, GA in 1.30). This maps the container's UID 0 to a non-root host UID without requiring changes to the container image.

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: userns-pod
spec:
  hostUsers: false  # Enable user namespace for this pod
  containers:
  - name: app
    image: nginx
    securityContext:
      runAsNonRoot: true  # Still checked — process must not be UID 0 inside the namespace
```

When `hostUsers: false`, the kubelet:
1. Creates a user namespace for the pod
2. Allocates UID/GID ranges from the node's `/etc/subuid` and `/etc/subgid`
3. Configures the container runtime to map container UIDs to the allocated range

**Interaction with Pod Security Standards**: The Kubernetes Restricted PSS profile requires `runAsNonRoot: true`. User namespaces do not relax this requirement — the process must still run as a non-zero UID inside the container. However, user namespaces add a second layer of isolation: even if the process runs as UID 0 inside, the host sees a non-root UID.

## Interaction with Other Security Mechanisms

### User Namespaces + Capabilities

Capabilities inside a user namespace are namespace-scoped. This means:
- `--cap-drop=ALL` still works inside a user namespace — the container's capability set is constrained
- `--cap-add=SYS_ADMIN` is less dangerous in a user namespace — the admin capability only applies to resources owned by the namespace
- Capability escalation to the host is impossible — the kernel caps capabilities at the user namespace boundary

### User Namespaces + Seccomp

Seccomp operates independently of user namespaces. The default Docker seccomp profile applies regardless of whether user namespaces are enabled. User namespaces do not bypass seccomp — both must be passed for a syscall to execute.

### User Namespaces + AppArmor / SELinux

- **AppArmor**: User namespaces and AppArmor are orthogonal. The AppArmor profile constrains file access inside the namespace.
- **SELinux**: MCS labels provide additional isolation between containers, supplementing user namespace UID mapping.

### User Namespaces + Read-Only Filesystem

A read-only root filesystem works the same inside a user namespace. The user namespace does not make read-only filesystems writable.

## Practical Concerns

### Volume Permissions

The single biggest practical problem with user namespaces:

```bash
# Without user namespaces — works
docker run -v /home/user/data:/data alpine touch /data/test

# With --userns-remap — fails
# Container's UID 0 is host UID 100000
# /home/user/data is owned by UID 1000
```

Solutions:
1. **Rootless Docker**: `fuse-overlayfs` handles UID translation transparently.
2. **Podman**: Uses `--userns=keep-id` to keep the container UID matching the host UID for bind-mounted volumes.
3. **Init container chown**: Run an init container as root to chown the volume to the mapped range.
4. **Kubernetes `fsGroup`**: When a pod has `fsGroup`, Kubernetes recursively changes the volume ownership to the group before the container starts.

### --privileged Behavior

`--privileged` is less powerful inside a user namespace. The container gains all capabilities, but they are namespace-scoped. Operations that affect the host kernel (loading modules, `swapon`, rebooting) still fail because the kernel checks the target resource's owning user namespace.

```bash
# rootful Docker, no user namespace
docker run --privileged alpine modprobe dummy
# Works — host kernel accepts the module

# with --userns-remap
docker run --privileged alpine modprobe dummy
# Fails — capabilities are scoped to the user namespace
```

### Debugging User Namespace Issues

```bash
# Check the UID mapping
cat /proc/self/uid_map

# Check the GID mapping
cat /proc/self/gid_map

# Check user namespace identity
ls -l /proc/self/ns/user

# Compare with parent namespace
cat /proc/self/status | grep ^Uid:
# Uid:	0	100000	100000	100000
#      Real Effective Saved FS
```

## The Security Boundary

The kernel enforces the user namespace boundary at multiple levels:
1. **UID/GID isolation**: A process outside the namespace cannot access files owned by UIDs inside the namespace, and vice versa.
2. **Capability scoping**: Capabilities are confined to resources owned by the namespace.
3. **Signal delivery**: `kill()` across user namespace boundaries requires `CAP_SYS_PTRACE` in the **target's** user namespace.
4. **ptrace**: Cross-ns ptrace is blocked unless the tracer has `CAP_SYS_PTRACE` in both its own and the target's user namespace.
5. **Process visibility**: `/proc/PID/` entries from different user namespaces are filtered by the kernel's access check.

This is why user namespaces are considered a stronger isolation boundary than running as non-root without user namespaces — they add kernel-enforced UID isolation that a container breakout cannot escape without a kernel vulnerability.

### Known Weaknesses

User namespaces are not perfect. The following attack vectors exist:
- **`/proc/sys/kernel/` writeability**: Some kernel parameters are not namespaced. The kernel has gradually closed these over time.
- **`userfaultfd`**: In kernels before 5.11, `userfaultfd` allowed denial-of-service via page fault handling in user namespaces.
- **`FUSE` permission bypass**: Before kernel 5.15, FUSE filesystems could bypass permission checks in user namespaces.
- **`Overlayfs` privilege escalation**: CVE-2021-3493 (kernel 5.11) allowed a user namespace to escape via overlayfs `setattr` operations.

These are kernel CVEs — user namespaces reduce the blast radius but do not eliminate kernel attack surface entirely.

## The Industry Shift Toward User Namespaces as Default

| Platform | Status |
|----------|--------|
| **Podman** | User namespaces enabled by default since early versions |
| **Rootless Docker** | User namespaces by definition (stable since 20.10) |
| **Rootful Docker** | Still off by default; `--userns-remap` required |
| **Kubernetes** | `hostUsers: false` beta in 1.27, stable in 1.30 |
| **OCI Runtime Spec** | `linux.namespaces` includes `"type": "user"` with `uidMappings` and `gidMappings` fields |

The long-term direction: user namespaces will become the default for all containers. Remaining blockers:
1. **Compatibility**: Volume permissions and port binding breakages need transparent solutions
2. **Performance**: `fuse-overlayfs` is slower than `overlay2`; kernel improvements are closing the gap
3. **Feature parity**: BPF-based networking, cgroup delegation need kernel namespace support

## Interview Tips

- **User namespaces are the only namespace unprivileged processes can create.** This is the key fact that enables rootless containers.
- **Capabilities in a user namespace are namespace-scoped.** This is the most commonly misunderstood aspect — `--privileged` inside a user namespace does not give host root.
- **User namespaces solve the UID reuse problem.** The `nobody` cross-container signaling risk is eliminated because different containers get different host UID mappings.
- **Docker chose compatibility over security.** User namespaces off by default for a decade is the canonical example.
- **User namespaces are the foundation of rootless containers.** Rootless Docker, rootless Podman, and BuildKit's rootless mode all depend on them.
- **Know the `/etc/subuid` delegation model.** This is the mechanism that makes user namespaces work at scale in multi-user systems.
- **K8s 1.27+ per-pod user namespaces are a game changer.** They let Kubernetes provide user namespace isolation without requiring changes to container images or daemon configuration.

## Cross-References

- [Non-Root Execution](non-root-execution.md) — UID allocation and USER directive
- [Linux Capabilities](linux-capabilities.md) — capability model in containers
- [Docker Architecture](../docker/docker-architecture.md) — rootless mode and runc startup sequence
- [/proc and Container Isolation](../linux-fundamentals/proc-container-isolation.md) — kernel access check and user namespaces
- [Seccomp](seccomp.md) — syscall filtering orthogonal to user namespaces
- [AppArmor/SELinux](apparmor-selinux.md) — LSM interaction with user namespaces
