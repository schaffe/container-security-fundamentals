---
title: "/proc and Container Isolation"
section: "Linux Fundamentals"
order: 37
---

# /proc and Container Isolation

## What Is /proc?

`/proc` is a **pseudo-filesystem** — no real files, no disk storage. The kernel populates it on-the-fly as you read it. Every file is a live view of kernel state: process information, memory mappings, hardware configuration, kernel tunables.

```bash
# It's a virtual filesystem — nothing on disk
$ mount | grep proc
proc on /proc type proc (rw,relatime)
```

The kernel exposes data through `/proc` so userspace tools (`ps`, `top`, `lsof`, `mount`) have a standard interface to read kernel state without needing custom syscalls for every piece of information.

## What Lives in /proc

### Per-Process Entries

Every running process gets a `/proc/PID/` directory:

| Entry | Contents | Security Relevance |
|---|---|---|
| `/proc/PID/cmdline` | Command line arguments | Reveals running commands |
| `/proc/PID/status` | State, UIDs, GIDs, capabilities, seccomp mode | Detects privilege state |
| `/proc/PID/maps` | Memory mappings (libraries, heap, stack) | Reveals ASLR layout, library versions |
| `/proc/PID/environ` | Environment variables | May contain secrets, API keys |
| `/proc/PID/fd/` | Open file descriptors (symlinks to real files) | Access to open files across processes |
| `/proc/PID/root/` | Symlink to process's rootfs | Traversal to container filesystem |
| `/proc/PID/exe` | Symlink to the executable binary | Binary overwrite attacks (CVE-2019-5736) |
| `/proc/PID/mem` | Process memory (read/write with ptrace) | Memory injection |
| `/proc/PID/ns/` | Namespace inodes (mnt, pid, net, user) | Namespace identification |

`/proc/self/` is a symlink to `/proc/<current-PID>` — a process can always reference itself without knowing its PID.

### Global Entries

| Entry | Contents | Security Relevance |
|---|---|---|
| `/proc/cpuinfo` | CPU details | Low risk |
| `/proc/meminfo` | Memory usage | Low risk |
| `/proc/mounts` | Mounted filesystems | Reveals host mounts (symlink to `/proc/self/mounts`) |
| `/proc/uptime` | System uptime | Low risk |
| `/proc/version` | Kernel version | Reveals kernel version for exploit targeting |
| `/proc/kcore` | Full kernel memory dump (entire physical RAM) | **Extreme** — kernel memory, passwords, crypto keys |
| `/proc/kallsyms` | Kernel symbol table | ASLR bypass for kernel exploits |
| `/proc/keys` | Cryptographic keys in kernel keyring | **High** — key leakage |
| `/proc/timer_list` | Kernel timer list | Low risk |
| `/proc/sched_debug` | Scheduler debug data | Low risk |

### Tunables: /proc/sys/

`/proc/sys/` is the **sysctl interface** — kernel parameters exposed as files:

```bash
# Read a kernel parameter
cat /proc/sys/net/ipv4/ip_forward
# Write a kernel parameter (requires privileges)
echo 1 > /proc/sys/net/ipv4/ip_forward
```

Writing to `/proc/sys/` modifies kernel behavior at runtime. Docker restricts this in containers via read-only mounts and dropped capabilities.

## How the Kernel Creates /proc

When you mount procfs, the kernel creates a procfs instance tied to a specific PID namespace:

```c
mount("proc", "/proc", "proc", MS_NOSUID|MS_NODEV|MS_NOEXEC, NULL);
```

The mount options `MS_NOSUID|MS_NODEV|MS_NOEXEC` prevent setuid binaries, device nodes, and code execution from within the procfs — defense-in-depth even if an attacker finds a writable `/proc` entry.

The critical behavior: **procfs is namespace-aware**. The kernel filters `/proc` content based on the PID namespace of the mount. A procfs mounted inside a PID namespace shows only processes in that namespace.

## How Docker Virtualizes /proc via PID Namespaces

### Without Containers

On the host, `/proc/PID/` shows every process on the system:

```
Host /proc:
  /proc/1/      → systemd
  /proc/500/    → dockerd
  /proc/1200/   → containerd
  /proc/1500/   → runc init
  /proc/1600/   → nginx (in container)
  /proc/1700/   → postgres (in another container)
```

### With a PID Namespace

When Docker creates a container, runc:

1. Calls `clone()` with `CLONE_NEWPID` to create a new PID namespace
2. Mounts a **fresh procfs** inside the namespace: `mount("proc", "/proc", "proc", 0, NULL)`"

Because the mount happens inside the new PID namespace, the kernel filters `/proc` to show only processes in that namespace:

```
Container /proc:
  /proc/1/      → nginx (container init)
  /proc/1/      → NOT systemd (invisible)
```

PID 1 inside the container is the container's init process (nginx, in this example). The host's systemd never appears. This is not hiding — the kernel genuinely doesn't expose PIDs from other namespaces through this procfs mount.

### The runc Startup Sequence

```
runc create
  → clone(CLONE_NEWPID|CLONE_NEWNS|...) → child process (runc init)
    → runc init enters new namespaces
    → mount("proc", "/proc", "proc", 0, NULL)  ← fresh procfs for this PID namespace
    → pivot_root into container rootfs
    → execve(container CMD)
```

The procfs mount happens **after** `clone()` but **before** `execve`. This guarantees that the container's `/proc` is a pristine, namespace-filtered procfs from the moment the application starts.

## The Kernel Access Check

Access to `/proc/PID/` entries is governed by a kernel capability check in `proc_pid_permission()`:

```
if (uid_of_reader == uid_of_target)
    → full access to /proc/PID/{maps, mem, environ, fd/, root/, ...}
else if (reader has CAP_SYS_PTRACE in the target's user namespace)
    → full access
else
    → only /proc/PID/{status, cmdline, ...} visible (world-readable)
```

This is the intersection of UID and PID namespace isolation. Three cases:

### Case 1: Different PID Namespaces

The container can't even enumerate the other container's PIDs. The `/proc` directory simply doesn't contain entries for processes outside the namespace. **Fully isolated.**

### Case 2: Same PID Namespace, Different UIDs

The container can see the other process's PID directory, but can't read its `maps`, `mem`, `environ`, or `fd/` because the UID check fails. **Partially isolated** — metadata visible, sensitive data protected.

### Case 3: Same PID Namespace, Same UID

The container has full access to the other process's `maps`, `mem`, `environ`, `fd/`, and `root/`. This is the cross-container signaling risk: two containers both running as UID 10001 (or `nobody`) can read each other's secrets and inject into each other's memory.

| Scenario | PID Namespace | UID Match | `/proc/PID/` Access |
|---|---|---|---|
| Different containers (user namespaces) | Different | N/A | No visibility |
| Same UID, no user namespace | Different | N/A | No visibility |
| Different UIDs, shared PID NS | Same | No | Metadata only |
| Same UID, shared PID NS | Same | Yes | **Full access** |

## Attack Surface via /proc in Containers

### 1. CVE-2019-5736 — `/proc/self/exe` Race

This is the most devastating `/proc` exploit in Docker's history. During container startup, runc opens `/proc/self/exe` to read or write its own binary. At that point, runc is inside the container's namespaces (including PID namespace) but still running as root before `execve`. A malicious process already in the container can:

1. `ptrace` the runc init process (shared PID namespace)
2. Overwrite `/proc/self/exe` with arbitrary code
3. When runc exits, the host executes the attacker's payload as **root on the host**

The fix was to open the binary FD **before** entering namespaces, with `O_CLOEXEC`, so the container never has access to the FD.

### 2. `/proc/kcore` — Full Kernel Memory

`/proc/kcore` is an ELF core dump of the entire kernel memory — all physical RAM. Reading it reveals everything: running processes, file contents in cache, crypto keys, passwords. Docker masks this path by over-mounting it with an empty tmpfs file.

### 3. `/proc/sys/` — Kernel Parameter Modification

Writing to `/proc/sys/net/ipv4/ip_forward` changes the host's network stack. Writing to `/proc/sys/kernel/core_pattern` can redirect crash dumps. Writing to `/proc/sys/kernel/panic` can cause denial of service. Docker blocks this by making `/proc/sys` read-only and dropping `CAP_SYS_ADMIN`.

### 4. `/proc/PID/environ` — Secret Leakage

Environment variables commonly contain secrets: `AWS_SECRET_ACCESS_KEY`, `DB_PASSWORD`, `API_TOKEN`, `JWT_SECRET`. If two containers share a PID namespace and run as the same UID, one can read the other's `environ`. With user namespaces or unique UIDs, this is blocked at the kernel level.

### 5. `/proc/PID/root/` — Filesystem Traversal

`/proc/PID/root/` is a symlink to the process's root directory (as established by `pivot_root` or `chroot`). If a container shares a PID namespace with another container and runs as the same UID, it can follow `/proc/OTHER_PID/root/home/appuser/config.yaml` to read the other container's files — bypassing filesystem isolation entirely.

### 6. `/proc/PID/` — Open File Descriptor Inspection

`/proc/PID/fd/` contains symlinks to every open file descriptor. This includes:
- **Sockets** — reading socket data
- **Pipes** — intercepting inter-process communication
- **Regular files** — accessing files the process has open
- **Eventfd, signalfd** — interfering with process synchronization

### 7. `/proc/PID/maps` — ASLR Bypass

The memory map reveals the exact addresses of libraries, heap, and stack. This defeats ASLR — an attacker who can read another process's `maps` knows exactly where to inject shellcode or ROP chains.

### 8. `/proc/PID/mem` — Direct Memory Injection

With ptrace access, a process can read and write another process's memory via `/proc/PID/mem`. This allows:
- Reading in-flight data (decrypted secrets, partial computations)
- Injecting shellcode directly into the process's address space
- Modifying return addresses, function pointers, or security checks

## Docker's Defenses: MaskedPaths and ReadonlyPaths

Docker protects `/proc` through two mechanisms in the OCI runtime spec:

### MaskedPaths

These paths are **over-mounted with an empty tmpfs file** — the file exists but is empty and unwritable:

```json
"maskedPaths": [
  "/proc/kcore",
  "/proc/keys",
  "/proc/latency_stats",
  "/proc/timer_list",
  "/proc/sched_debug"
]
```

```bash
# Container sees an empty file
docker run --rm alpine cat /proc/kcore
# (no output — file exists but is empty)
```

The kernel allows over-mounting individual files within procfs because they're regular files, not directories. An empty tmpfs file satisfies the path existence check but yields no data.

### ReadonlyPaths

These paths are **bind-mounted read-only** — they exist and can be read but not modified:

```json
"readonlyPaths": [
  "/proc/bus",
  "/proc/fs",
  "/proc/irq",
  "/proc/sys"
]
```

```bash
# Container can read but not write
docker run --rm alpine touch /proc/sys/test
# touch: /proc/sys/test: Read-only file system
```

### What This Means

| Path | Defense | Access |
|---|---|---|
| `/proc/kcore` | Masked | Empty file |
| `/proc/keys` | Masked | Empty file |
| `/proc/sched_debug` | Masked | Empty file |
| `/proc/timer_list` | Masked | Empty file |
| `/proc/latency_stats` | Masked | Empty file |
| `/proc/sys/` | Read-only | Readable, not writable |
| `/proc/bus` | Read-only | Readable, not writable |
| `/proc/fs` | Read-only | Readable, not writable |
| `/proc/irq` | Read-only | Readable, not writable |
| Everything else | Unrestricted | Normal procfs access |

The unrestricted entries include `/proc/self/` and `/proc/PID/` — these are controlled by PID namespaces and UID checks, not by path masking.

## procMount in Kubernetes

Kubernetes exposes a `procMount` field in the `SecurityContext`:

```yaml
securityContext:
  procMount: DefaultProcMount  # Default — applies MaskedPaths + ReadonlyPaths
```

Two options:

| Mode | Behavior |
|---|---|
| `DefaultProcMount` (default) | Applies the OCI default masked and read-only paths |
| `UnmaskedProcMount` | Removes all `/proc` restrictions — container has full host-level `/proc` access |

`UnmaskedProcMount` requires a `PodSecurityPolicy` or admission controller exemption — it is effectively privileged access.

### Pod Security Standards

The Kubernetes **Restricted** PSS profile requires `DefaultProcMount`:

```yaml
# Restricted profile enforces:
spec.containers[].securityContext.procMount == "DefaultProcMount"
```

This blocks `UnmaskedProcMount` in restricted namespaces. The **Baseline** profile also requires it.

## Practical Verification

```bash
# Compare host vs container process list
docker run --rm alpine ps aux
# Only one process — the shell itself

# Check PID 1 inside container
docker run --rm alpine cat /proc/1/cmdline
# /bin/sh (not systemd)

# Verify masked paths are empty
docker run --rm alpine ls -la /proc/kcore
# -rw------- 1 root root 0 ... /proc/kcore  (size 0)
docker run --rm alpine wc -c /proc/kcore
# 0 /proc/kcore

# Verify read-only paths
docker run --rm alpine touch /proc/sys/test
# touch: /proc/sys/test: Read-only file system

# Check namespace identity
docker run --rm alpine ls -l /proc/self/ns/
# Each namespace has a unique inode for this container
```

## Dead-End Paths

What a container **cannot** access even as root inside the container:

| Path | Why blocked | Impact |
|---|---|---|
| `/proc/kcore` | Masked (empty) | No kernel memory dump |
| `/proc/sched_debug` | Masked (empty) | No scheduler information leak |
| `/proc/keys` | Masked (empty) | No key leakage |
| `/proc/timer_list` | Masked (empty) | No timer information |
| `/proc/latency_stats` | Masked (empty) | No latency data |
| `/proc/bus` | Read-only | No bus manipulation |
| `/proc/irq` | Read-only | No IRQ manipulation |
| `/proc/fs` | Read-only | No filesystem parameter changes |
| `/proc/sys/kernel/core_pattern` | Read-only + no `CAP_SYS_ADMIN` | No crash dump redirection |
| `/proc/sys/kernel/panic` | Read-only + no `CAP_SYS_ADMIN` | No panic trigger |
| `/proc/PID/` of other containers | PID namespace isolation | No visibility into other containers |

## Quiz

- Why can't a container see host processes in `/proc`?
- What's the difference between a masked path and a read-only path?
- How does the kernel check access to `/proc/PID/maps`?
- How does a user namespace prevent `/proc/PID/` access even with shared PIDs?
- What vulnerability is `/proc/self/exe` associated with?

## Further Reading

- [Docker Architecture: runc startup sequence](../articles/30-docker-architecture.md)
- [Non-Root Execution: UID allocation and cross-container /proc risk](../articles/10-non-root-execution.md)
- [Seccomp: ptrace filtering and /proc/self/exe](../articles/12-seccomp.md)
- [AppArmor/SELinux: /proc path deny rules](../articles/13-apparmor-selinux.md)
- [Pod Security Standards: DefaultProcMount requirement](../articles/17-pod-security-standards.md)
- [SecurityContext vs PodSecurityContext: procMount field](../articles/16-securitycontext-vs-podsecuritycontext.md)
- [Read-only Filesystem: /proc/self/exe as hidden write path](../articles/14-readonly-filesystem.md)
