---
title: "SecurityContext vs PodSecurityContext in Kubernetes"
section: "Helm Chart Security Adaptation"
order: 16
---

# SecurityContext vs PodSecurityContext in Kubernetes

When hardening Kubernetes workloads, SecurityContext is the primary mechanism for controlling permissions at both the pod and container levels. Understanding the distinction, overlap, and cascade behavior between `pod.spec.securityContext` and `container.securityContext` is essential — and is one of the most common interview topics for supply chain security roles.

## PodSecurityContext (Pod Level)

`PodSecurityContext` is set at `spec.securityContext` in a Pod spec. It applies to **all containers** in the pod unless overridden. It cannot set container-specific fields like `capabilities` or `privileged` mode.

Key fields:

| Field | Purpose |
|---|---|
| `runAsUser` | UID for all processes in the pod |
| `runAsGroup` | GID for all processes |
| `runAsNonRoot` | Reject if container runs as UID 0 |
| `fsGroup` | Ownership of mounted volumes |
| `supplementalGroups` | Additional GIDs for the process |
| `seLinuxOptions` | SELinux labels applied to all containers |
| `seccompProfile` | seccomp profile (Localhost, RuntimeDefault, Unconfined) |
| `sysctls` | Namespace-level sysctl settings |
| `fsGroupChangePolicy` | Always vs OnRootMismatch for volume ownership |

### Example: PodSecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: hardened-pod
spec:
  securityContext:
    runAsUser: 1001
    runAsGroup: 3000
    fsGroup: 2000
    supplementalGroups: [4000, 5000]
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    seLinuxOptions:
      level: "s0:c123,c456"
  containers:
    - name: app
      image: myapp:1.0
```

## SecurityContext (Container Level)

Set at `containers[].securityContext`. This is where **fine-grained controls** live: capabilities, privilege escalation, read-only root filesystem, and container-specific user identities.

Key fields:

| Field | Purpose |
|---|---|
| `capabilities` | Add/drop Linux capabilities via `add`/`drop` lists |
| `privileged` | Run container with full host privileges |
| `runAsUser` | Override pod-level UID for this container |
| `runAsGroup` | Override pod-level GID for this container |
| `runAsNonRoot` | Override pod-level non-root check |
| `readOnlyRootFilesystem` | Mount root filesystem read-only |
| `allowPrivilegeEscalation` | Control `no_new_privs` (defaults to true if privileged) |
| `procMount` | Mount [`/proc`](../articles/37-proc-container-isolation.md#procmount-in-kubernetes) as unmasked (default: DefaultProcMount) |
| `seccompProfile` | Override pod-level seccomp for this container |
| `capabilities.drop` | Drop all with `["ALL"]` |
| `seLinuxOptions` | Override pod-level SELinux context |

### Example: Container SecurityContext

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: container-hardened
spec:
  containers:
    - name: app
      image: myapp:1.0
      securityContext:
        runAsUser: 1002
        runAsNonRoot: true
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
        seccompProfile:
          type: RuntimeDefault
```

## Cascade Behavior

The pod-level SecurityContext serves as a **default** that container-level settings override. The relationship is:

1. Pod-level `runAsUser`, `runAsGroup`, `runAsNonRoot` apply to all containers unless a container explicitly sets its own.
2. Pod-level `fsGroup`, `supplementalGroups`, `fsGroupChangePolicy` apply only at the pod level and **cannot** be overridden per container.
3. Container-level `runAsUser` **overrides** pod-level `runAsUser` for that container.
4. `capabilities`, `privileged`, `readOnlyRootFilesystem`, and `allowPrivilegeEscalation` only exist at the container level.

### Mermaid: How Settings Cascade

```
PodSecurityContext (defaults for all containers)
 ├── runAsUser ─────── can be overridden per container
 ├── runAsGroup ────── can be overridden per container
 ├── runAsNonRoot ──── can be overridden per container
 ├── seccompProfile ── can be overridden per container
 ├── seLinuxOptions ── can be overridden per container
 ├── fsGroup ───────── applied once to volumes (not per container)
 └── supplementalGroups ── applied process-wide

ContainerSecurityContext (container-specific)
 ├── runAsUser ─────── overrides pod value
 ├── capabilities ──── only at container level
 ├── privileged ────── only at container level
 ├── readOnlyRootFilesystem ── only at container level
 └── allowPrivilegeEscalation ── only at container level
```

## Common Patterns in Hardened Deployments

### Pattern 1: Restricted Pod with Capability Exception

Some containers genuinely need `NET_BIND_SERVICE` to bind to ports below 1024. The rest do not.

```yaml
spec:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
    - name: proxy
      securityContext:
        runAsUser: 1001
        capabilities:
          drop: ["ALL"]
          add: ["NET_BIND_SERVICE"]
    - name: sidecar
      securityContext:
        runAsUser: 1002
        capabilities:
          drop: ["ALL"]
```

### Pattern 2: readOnlyRootFS with EmptyDir for Temp Writes

```yaml
spec:
  securityContext:
    runAsNonRoot: true
  containers:
    - name: app
      securityContext:
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      volumeMounts:
        - name: tmp
          mountPath: /tmp
  volumes:
    - name: tmp
      emptyDir: {}
```

## Interview Deep Dive

**Q:** If the pod SecurityContext sets `runAsUser: 1000` and a container sets `runAsUser: 2000`, which wins?

**A:** The container wins. `container.securityContext.runAsUser` takes precedence over `pod.spec.securityContext.runAsUser` for that specific container.

**Q:** Can `fsGroup` be set per container?

**A:** No. `fsGroup` is a pod-level field. It controls the ownership of all volumes mounted in the pod and is applied as a single operation. The group ownership change happens once to the volume, not per container.

**Q:** Why drop `ALL` capabilities and add back selectively?

**A:** Defense in depth. The principle of least privilege means starting from zero. K8s containers get a default set capabilities that are almost never needed (e.g., `CHOWN`, `DAC_OVERRIDE`, `FOWNER`, `FSETID`, `KILL`, `SETGID`, `SETUID`, `SETPCAP`, `NET_RAW`). Dropping `ALL` then explicitly adding back only what's required (e.g., `NET_BIND_SERVICE`) minimizes kernel attack surface.

**Q:** What happens if `readOnlyRootFilesystem: true` is set but the container writes to `/` at runtime?

**A:** The container will crash with a write error. This is a common breaking change when hardening existing images. Fixes include: write to an `emptyDir` volume mounted at the writable path, or ensure the image writes to `/tmp` or a designated volume path.
