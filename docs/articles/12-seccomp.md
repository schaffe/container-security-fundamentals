---
title: "Seccomp Profiles for Containers"
section: "Container Image Hardening"
order: 5
---

# Seccomp Profiles for Containers

Seccomp (Secure Computing Mode) is a Linux kernel feature that restricts the system calls a process can make. It acts as a second line of defense — even if a container process is compromised and running with capabilities, seccomp can block the syscalls needed for kernel exploitation.

## How Seccomp Works

Seccomp installs a BPF (Berkeley Packet Filter) program that intercepts every system call before execution. The filter can:

- **Allow** the syscall (with optional argument filtering)
- **Deny** the syscall (return -EPERM or -EACCES, killing the process with SIGSYS)
- **Trap** to userspace handler
- **Trace** via ptrace

Docker's default profile uses "allow on default action, deny on specific match" — listing the ~300 syscalls that are explicitly allowed and denying everything else by default.

### Seccomp Action Values

| Action | Behavior | Use Case |
|---|---|---|
| `SCMP_ACT_ALLOW` | Allow syscall execution | Permitted syscalls |
| `SCMP_ACT_ERRNO` | Return error code (EPERM) | Blocked syscalls, graceful handling |
| `SCMP_ACT_KILL_PROCESS` | Kill the process with SIGSYS | Dangerous syscalls |
| `SCMP_ACT_KILL_THREAD` | Kill the offending thread | Legacy behavior |
| `SCMP_ACT_TRAP` | Trap to userspace handler | Debugging |
| `SCMP_ACT_LOG` | Allow but log (Linux 4.14+) | Auditing before switching to deny |

## Docker's Default Seccomp Profile

Docker ships with a default seccomp profile that allows ~300 of the ~450 total Linux syscalls. The profile is critical for container security because it blocks kernel exploits that use uncommon but dangerous syscalls.

### Syscalls Blocked by Default

Key blocked syscalls and their exploit relevance:

| Blocked Syscall | Why It's Blocked |
|---|---|
| `mount` | Namespace escape via pivot_root, bind mounts, overlay |
| `umount` | Unmounting filesystem boundaries |
| `ptrace` | Process inspection, code injection, escape via ptrace |
| `swapon` / `swapoff` | Denial of service, resource exhaustion |
| `kexec_file_load` | Boot kernel takeover |
| `bpf` | BPF JIT spraying, kernel code execution |
| `perf_event_open` | Kernel information leak (e.g., Meltdown) |
| `open_by_handle_at` | Container escape via handle-based file access |
| `name_to_handle_at` | Used with open_by_handle_at for escape |
| `init_module` / `delete_module` | Kernel module loading |
| `setdomainname` / `sethostname` | Break container isolation assumptions |
| `reboot` | System shutdown |
| `iopl` / `ioperm` | Port I/O access, HID attacks |
| `process_vm_readv` / `process_vm_writev` | Cross-process memory access |
| `nfsservctl` | NFS server inside container |

### Docker Default Profile Location

```bash
# Default profile built into dockerd
# On most systems, you can find it at:
ls /etc/docker/seccomp.json  # Usually not present — it's built into the daemon

# Inspect the default by running:
docker run --rm alpine cat /proc/1/status | grep Seccomp
# Output: Seccomp:	2  (filtered mode)

# Dump the default profile from Docker source:
docker run --rm -it alpine sh -c "apk add -q curl && curl -s https://raw.githubusercontent.com/moby/moby/master/profiles/seccomp/default.json | head -50"
```

## RuntimeDefault vs Custom Profiles

Kubernetes 1.19+ introduced the `RuntimeDefault` seccomp profile, which applies the container runtime's default (Docker/containerd's default seccomp profile):

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-pod
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault  # Applies the default seccomp profile
  containers:
  - name: app
    image: myapp
```

### Custom Seccomp Profiles

When `RuntimeDefault` blocks a syscall your application needs, you must write a custom profile:

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64", "SCMP_ARCH_AARCH64"],
  "syscalls": [
    {
      "names": [
        "accept4",
        "bind",
        "clock_gettime",
        "clone",
        "close",
        "connect",
        "epoll_create1",
        "epoll_ctl",
        "epoll_pwait",
        "exit",
        "exit_group",
        "fchown",
        "fcntl",
        "fstat",
        "fstatfs",
        "ftruncate",
        "getdents64",
        "getpeername",
        "getpid",
        "getsockname",
        "getsockopt",
        "listen",
        "lseek",
        "madvise",
        "mmap",
        "mprotect",
        "munmap",
        "nanosleep",
        "newfstatat",
        "openat",
        "pread64",
        "prlimit64",
        "pwrite64",
        "read",
        "readlinkat",
        "recvfrom",
        "recvmsg",
        "rt_sigaction",
        "rt_sigprocmask",
        "rt_sigreturn",
        "sched_getaffinity",
        "sched_yield",
        "sendmsg",
        "sendto",
        "set_robust_list",
        "set_tid_address",
        "setsockopt",
        "shutdown",
        "sigaltstack",
        "socket",
        "statfs",
        "tgkill",
        "write",
        "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    },
    {
      "names": ["personality"],
      "action": "SCMP_ACT_ALLOW",
      "args": [
        {
          "index": 0,
          "value": 0,
          "op": "SCMP_CMP_EQ"
        }
      ]
    }
  ]
}
```

This profile only allows the syscalls an HTTP Go server needs. All other syscalls return `-EPERM` (`SCMP_ACT_ERRNO`).

### Determining Required Syscalls

Use `strace` to identify which syscalls your application makes:

```bash
# On the host (not recommended — syscall numbers differ between kernels)
strace -c -S calls ./myapp

# Better: run with seccomp logging and inspect
docker run --security-opt seccomp=unconfined --security-opt no-new-privileges alpine \
    strace -c -o /tmp/syscalls.txt /app
```

Or use `audit2allow`-style tooling:

```bash
# Install inspektor-gadget to trace syscalls
kubectl gadget trace syscall --podname mypod
```

## Writing Custom Profiles for Specific Applications

### Web Server (nginx) Profile

```json
{
  "defaultAction": "SCMP_ACT_ERRNO",
  "architectures": ["SCMP_ARCH_X86_64"],
  "syscalls": [
    {
      "names": [
        "accept", "accept4", "access", "bind", "brk", "clock_gettime",
        "clone", "close", "connect", "dup", "epoll_create",
        "epoll_create1", "epoll_ctl", "epoll_wait", "eventfd2",
        "execve", "exit_group", "fchmod", "fchown", "fcntl",
        "fdatasync", "fstat", "fsync", "ftruncate", "futex",
        "getdents", "getdents64", "getegid", "geteuid", "getgid",
        "getpeername", "getpgrp", "getpid", "getppid", "getrandom",
        "getsockname", "getsockopt", "gettid", "getuid", "ioctl",
        "ioprio_get", "listen", "lseek", "madvise", "mkdir",
        "mmap", "mprotect", "munmap", "nanosleep", "newfstatat",
        "open", "openat", "pipe", "pipe2", "poll", "pread64",
        "prlimit64", "pwrite64", "read", "readlink", "readlinkat",
        "recvfrom", "recvmmsg", "recvmsg", "rename", "rt_sigaction",
        "rt_sigprocmask", "rt_sigreturn", "rt_sigtimedwait",
        "sched_getaffinity", "sched_setaffinity", "sched_yield",
        "sendfile", "sendmsg", "sendto", "set_robust_list",
        "set_tid_address", "setgid", "setgroups", "setsid",
        "setsockopt", "setuid", "shmget", "shmid", "shutdown",
        "sigaltstack", "socket", "socketpair", "splice", "stat",
        "statx", "tgkill", "time", "utimensat", "write", "writev"
      ],
      "action": "SCMP_ACT_ALLOW"
    }
  ]
}
```

### Applying Custom Profiles

```bash
# Create the profile file
cat > /etc/docker/profiles/nginx.json << 'EOF'
{ ... profile content ... }
EOF

# Run with custom profile
docker run --security-opt seccomp=/etc/docker/profiles/nginx.json nginx
```

## K8s Seccomp Configuration

Kubernetes supports several seccomp profile types:

### RuntimeDefault

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
```

### Localhost (custom profile file on node)

```yaml
apiVersion: v1
kind: Pod
spec:
  securityContext:
    seccompProfile:
      type: Localhost
      localhostProfile: profiles/nginx-seccomp.json  # Relative to kubelet seccomp dir
```

The profile must exist on every node at `/var/lib/kubelet/seccomp/profiles/nginx-seccomp.json`.

### Unconfined (no seccomp)

```yaml
seccompProfile:
  type: Unconfined
```

Never use this in production unless absolutely required.

## Seccomp + Capabilities: Defense in Depth

Seccomp and capabilities are complementary:

| Security Mechanism | Controls |
|---|---|
| **Capabilities** | Privileged operations (what a process is allowed to *do*) |
| **Seccomp** | System calls (what a process is allowed to *request*) |
| **AppArmor/SELinux** | File access, network access, process interactions |
| **Read-only filesystem** | Write access to specific paths |

A process might have `CAP_SYS_PTRACE` (capability) but have `ptrace` blocked by seccomp — the capability is irrelevant because the syscall never reaches the kernel's permission check.

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
  seccompProfile:
    type: RuntimeDefault
```

This is the minimum security baseline for production containers.

## Interview Tips

Understand that seccomp's primary value is **preventing kernel exploit primitives**. Many famous container escapes (CVE-2019-5736 runc, CVE-2022-0492 cgroup v1) relied on syscalls that the default profile allows. Know which syscalls are most dangerous to allow (`mount`, `ptrace`, `bpf`, `open_by_handle_at`). Be able to explain why `RuntimeDefault` on K8s 1.27+ has finally become the default — it took years because it broke legitimate applications. For more on how runc and containerd implement seccomp profiles, see [Docker Architecture](../articles/30-docker-architecture.md).
