---
title: "Linux Capabilities in Containers"
section: "Container Image Hardening"
order: 4
---

# Linux Capabilities in Containers

Linux capabilities break the binary "root vs non-root" model into fine-grained privileges. Each capability grants a specific permission (e.g., binding to a privileged port, changing file ownership, loading kernel modules). Containers use capabilities to grant processes elevated privileges without giving full root access.

## The Linux Capability Model

In traditional Unix, the `setuid` bit and UID 0 determine privilege. Capabilities divide root's power into ~40 distinct units. Each process has five capability sets:

1. **Effective (CapEff)**: The currently active capabilities
2. **Permitted (CapPrm)**: Capabilities the process can use (superset of effective)
3. **Inheritable (CapInh)**: Capabilities preserved across `execve()`
4. **Bounding (CapBnd)**: Capabilities a process can ever obtain
5. **Ambient (CapAmb)**: Capabilities preserved across `execve()` for non-root processes (Linux 4.3+)

```
Effective ⊆ Permitted ⊆ Bounding
Inheritable ⊆ Bounding
Ambient ⊆ (Permitted ∩ Inheritable)
```

## --cap-drop=ALL --cap-add Pattern

The Docker security best practice is to drop all capabilities and add back only what's needed:

```bash
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp
```

```yaml
# Kubernetes equivalent
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]
```

### Default Docker Capabilities

By default, Docker containers receive these capabilities (this is the `--cap-default` set):

| Capability | Purpose |
|---|---|
| **CHOWN** | Change file ownership |
| **DAC_OVERRIDE** | Bypass file permission checks |
| **FOWNER** | Bypass ownership checks on file operations |
| **FSETID** | Don't clear setuid/setgid on mode changes |
| **KILL** | Bypass permission checks for sending signals |
| **NET_BIND_SERVICE** | Bind to ports < 1024 |
| **NET_RAW** | Use raw and packet sockets |
| **SETGID** | Change GID |
| **SETUID** | Change UID |
| **SETPCAP** | Set process capabilities |
| **SYS_CHROOT** | Use [chroot()](../docker/docker-architecture.md#chroot-and-pivot_root) |
| **MKNOD** | Create device nodes |
| **AUDIT_WRITE** | Write to kernel audit log |
| **SETFCAP** | Set file capabilities |

A root container running with default capabilities has significantly more power than necessary. `--cap-drop=ALL` removes all 14, forcing explicit capability grants.

In a [user namespace](user-namespaces.md), capabilities are namespace-scoped — even `--privileged` only grants power over resources owned by the namespace.

## Capability Deep Dive

### CHOWN

Allows `chown()` system call. Without it, files created by root in the container remain owned by root, which can be a problem for shared volumes.

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["CHOWN"]  # Needed if app needs to change file ownership
```

### NET_BIND_SERVICE

The most commonly added capability. Allows binding to ports below 1024 as non-root.

```bash
docker run --cap-drop=ALL --cap-add=NET_BIND_SERVICE -p 80:80 myapp
```

### SYS_ADMIN

The most dangerous capability — it's essentially root. This capability enables:
- `mount()` and `umount()`
- `swapon()`
- `setdomainname()`
- Access to performance monitoring
- `pivot_root()`
- `nsenter()` (namespace manipulation)

**Never grant SYS_ADMIN in production**. If an application needs it, find a different architecture.

### SYS_PTRACE

Allows [ptrace()](seccomp.md#ptrace) system call — the ability to trace and debug
any process:

```dockerfile
# Needed for strace, perf, or debug containers
docker run --cap-add=SYS_PTRACE debugger
```

In production, leave this dropped.

### SYS_MODULE

Allows `init_module()` and `delete_module()` — loading kernel modules. If compromised, an attacker can load a malicious kernel module to escape the container.

### NET_ADMIN

Allows network administration: `iptables`, `ip link`, routing table modification, socket debugging.

### CAP_NET_RAW

Allows creation of raw sockets (`SOCK_RAW`). Tools like `ping` and `traceroute` require this. Also required for ICMP traffic.

## Ambient Capabilities for Non-root

Before Linux 4.3, capabilities were effectively useless for non-root processes because `execve()` would drop all capabilities when changing to a non-root user. Ambient capabilities (Linux 4.3+) fix this:

```bash
docker run --user 10001 --cap-drop=ALL --cap-add=NET_BIND_SERVICE --cap-add=NET_RAW myapp
```

Without ambient capabilities, the above command would break — the capability would be in Permitted but not Effective after `execve()`. Docker handles ambient capabilities automatically when using `--user` with `--cap-add`.

### Go Implementation of Capability Handling

```go
package main

import (
    "golang.org/x/sys/unix"
    "log"
)

func main() {
    // Check and apply capabilities at runtime
    header, err := unix.CapGet(0, nil)
    if err != nil {
        log.Fatalf("CapGet: %v", err)
    }

    caps := make([]unix.Cap, header.Caps)
    _, err = unix.CapGet(0, &caps)
    if err != nil {
        log.Fatalf("CapGet data: %v", err)
    }

    // If we have NET_BIND_SERVICE, bind to port 80
    for _, cap := range caps {
        if cap == unix.CAP_NET_BIND_SERVICE {
            // Bind to port 80
        }
    }
}
```

## K8s SecurityContext Capability Fields

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: capability-demo
spec:
  containers:
  - name: app
    image: nginx:alpine
    securityContext:
      capabilities:
        # Start with nothing, add exactly what's needed
        drop: ["ALL"]
        add:
        - NET_BIND_SERVICE   # Bind to port 80
        - CHOWN              # Change nginx log ownership
        - SETGID             # nginx worker processes change GID
        - SETUID             # nginx worker processes change UID
        - DAC_OVERRIDE       # nginx writes to log directory
      # Prevent privilege escalation via setuid binaries
      allowPrivilegeEscalation: false
      runAsNonRoot: true
      runAsUser: 101
```

### Tool: capsh for Testing Capabilities

```bash
# Test what capabilities a container command needs
docker run --rm --cap-drop=ALL alpine sh -c "apk add -q libcap && capsh --print"

# Run a binary and see if it fails due to missing capabilities
docker run --rm --cap-drop=ALL myapp
# If it fails, add capabilities incrementally:
docker run --rm --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp  # try 1
docker run --rm --cap-drop=ALL --cap-add=NET_RAW myapp           # try 2
```

### Auditing Capabilities with tini

A minimal init ([tini](../docker/docker-architecture.md#init-process-in-containers)) solves a practical problem when locking down capabilities: **the application must handle signals correctly** after you drop capabilities. Without tini, the application runs as PID 1 and Linux PID 1 ignores `SIGTERM`/`SIGINT` unless the app explicitly handles them. With `--cap-drop=ALL`, the app has no privileges to work around this — it either handles signals or gets `SIGKILL` after the 10s timeout.

```bash
# Tini as entrypoint + minimal capabilities = best practice
docker run --init --cap-drop=ALL --cap-add=NET_BIND_SERVICE myapp
```

**Why this works with no capabilities**: tini uses `kill()` within the same PID namespace and `waitpid()` — neither requires any privileges. `CAP_KILL` is only needed for crossing namespace boundaries. Tini forwards signals to its child process group using `kill(-pgid, sig)`, which is a standard unprivileged operation. This means you can pair the most restrictive capability set (`--cap-drop=ALL`) with proper init behavior.

Without `--init`, the application as PID 1 must be trusted to:
- Install a `SIGTERM` handler for graceful shutdown
- `waitpid()` any orphaned children to prevent zombie accumulation

With `--init`, tini handles both, decoupling init behavior from the application code — critical when you've dropped all capabilities and can't rely on workarounds.

See [Init Process in Containers](../docker/docker-architecture.md#init-process-in-containers) for detailed mechanics of tini, dumb-init, and when an init process is unnecessary.

## Common Capability Mappings by Application

| Application | Required Capabilities |
|---|---|
| **nginx** (port 80) | `NET_BIND_SERVICE`, `CHOWN`, `SETGID`, `SETUID`, `DAC_OVERRIDE` |
| **nginx** (port 8080) | `CHOWN`, `SETGID`, `SETUID`, `DAC_OVERRIDE` |
| **PostgreSQL** | `CHOWN`, `SETGID`, `SETUID`, `DAC_OVERRIDE`, `SYS_CHROOT` |
| **Redis** | `SETGID`, `SETUID` |
| **Node.js/Python/Go** app | (none with --cap-drop=ALL if port >= 1024) |
| **Prometheus** | (none) |
| **Envoy/HAProxy** (port < 1024) | `NET_BIND_SERVICE` |

## Creating a Minimal Capability Baseline

```dockerfile
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
USER 65532:65532

# Do NOT declare K8s capabilities in Dockerfile — it's an orchestration concern
CMD ["/app"]
```

```yaml
# k8s-deployment.yaml
securityContext:
  runAsNonRoot: true
  capabilities:
    drop: ["ALL"]
    # No add — this Go app binds to :8080 (non-privileged)
```

## Interview Tips

Discuss the **principle of least privilege** for containers. Be ready to explain why `--cap-drop=ALL --cap-add=NET_BIND_SERVICE` is safer than just not dropping capabilities. Understand the difference between capabilities and seccomp — capabilities control "what you are allowed to do" while seccomp controls "what system calls you can make." Know that capabilities don't help if the kernel itself has a vulnerability (they gate access to privileged operations, not the kernel code that implements them). For more on how the Docker engine manages capability sets, see [Docker Architecture](../docker/docker-architecture.md).
