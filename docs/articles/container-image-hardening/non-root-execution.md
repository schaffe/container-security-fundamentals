---
title: "Non-root Execution"
section: "Container Image Hardening"
order: 3
---

# Non-root Execution

Running containers as non-root is one of the most impactful container security hardening measures. By default, Docker runs processes as root (UID 0) inside the container, which — when combined with a container breakout — gives an attacker root access on the host. Non-root execution prevents this by ensuring the containerized process has minimal privileges.

## The USER Directive

The `USER` instruction in a Dockerfile sets the UID and GID for subsequent `RUN`, `CMD`, and `ENTRYPOINT` instructions.

```dockerfile
FROM node:20-slim
# Create a non-root user
RUN groupadd -r appgroup && useradd -r -g appgroup -m -d /home/appuser appuser
USER appuser
CMD ["node", "app.js"]
```

### Without USER (broken pattern)

```dockerfile
FROM alpine:3.19
# No USER directive — runs as root
CMD ["/usr/local/bin/myapp"]
```

If `myapp` is compromised, the attacker has root in the container. If they find a container escape (e.g., [CVE-2019-5736 runc](../docker/docker-architecture.md#cves)), they have root on the host.

## UID/GID Allocation Patterns

### UID 10001 (Application User)

The most common pattern is creating a dedicated application user with a high UID:

```dockerfile
FROM alpine:3.19
RUN adduser -D -u 10001 appuser
USER 10001
CMD ["/app"]
```

```dockerfile
FROM ubuntu:22.04
RUN groupadd --gid 10001 appgroup && \
    useradd --uid 10001 --gid appgroup --shell /bin/false --no-create-home appuser
USER appuser
```

Why a high UID? Low UIDs (0–999) are reserved for system users (daemons like `sshd`, `syslog`, `ntp`) and vary by distribution. A high UID avoids collisions. It also avoids accidental collisions with host users (e.g., UID 1000 often maps to a real developer account), which matters when bind-mounting volumes or during a container escape.

**Caveat — same UID across containers is the same problem as nobody**: If every container in your cluster runs as UID 10001, the cross-container signaling risk ([`/proc/PID` access](../linux-fundamentals/proc-container-isolation.md#the-kernel-access-check), `kill`, `ptrace`) is identical to using `nobody`. The UID number itself does not provide isolation — only **unique UIDs per workload** or **user namespaces** do. See [User Namespaces](#user-namespaces) below.

### UID 65534 (nobody)

The `nobody` user (UID 65534) exists on all Linux distributions:

```dockerfile
FROM alpine:3.19
USER 65534
CMD ["/app"]
```

The concerns with `nobody` are best understood in two categories:

**1. Shared-UID risk (applies to any reused UID)**: If multiple containers share the same UID, an attacker in one container can signal or interfere with processes in another — via [`/proc/PID` access](../linux-fundamentals/proc-container-isolation.md#the-kernel-access-check), `kill`, or `ptrace`. This is not specific to `nobody`; it applies equally to any UID (including 10001) used across multiple containers.

**2. `nobody`-specific issues**:
- **No home directory**: `nobody`'s home is typically `/nonexistent` or unset. Many runtimes (JVM, Node.js, Python, SSH) require a writable `$HOME` for caches, temp files, or config.
- **System daemon conflict**: `nobody` is already used by NFS, systemd-mapped services, and other kernel-managed tasks. Using it for an app creates ambiguity — is that process your app or a system daemon?
- **Unpredictable permissions**: Some kernels and distributions assign `nobody` special treatment in unprivileged user namespaces, leading to inconsistent behavior.

### User Namespaces

User namespaces (`CLONE_NEWUSER`) map a container's UID 0 to a non-privileged host UID range via `/etc/subuid` and `/etc/subgid`. When enabled, the kernel sees different containers as different host UIDs, enforcing [`/proc` isolation](../linux-fundamentals/proc-container-isolation.md#how-docker-virtualizes-proc-via-pid-namespaces), signal delivery, and file permissions at the kernel level — even when two containers run the same internal UID.

**User namespaces are OFF by default in rootful Docker.** The container shares the host UID namespace, so UID 10001 in the container is host UID 10001. The trade-off: compatibility. Volume permissions, `--privileged`, and port binding all behave differently with user namespaces.

See [User Namespaces in Containers](user-namespaces.md) for the full kernel mechanics, `/etc/subuid` delegation, Docker's `--userns-remap`, rootless mode, Podman's model, Kubernetes per-pod user namespaces, and the industry shift toward user namespaces as default.

**Recommendation**: Use a dedicated high UID (e.g., 10001) per application for correct runtime behavior (home directory, file ownership, audit trail). **Use different UIDs per app or enable user namespaces (prefer rootless Docker)** to prevent cross-container interference. If user namespaces aren't feasible, different UIDs per workload is the next best option. Prefer `nobody` only when no writable paths are needed and the image provides no other user — but be aware of its limitations.

### Distroless Non-root Variants

Google's distroless images ship with a pre-configured non-root user:

```dockerfile
FROM gcr.io/distroless/base-debian12:nonroot
# UID 65532 in the nonroot variant
USER 65532:65532
CMD ["/app"]
```

## --security-opt=no-new-privileges

Even when running as non-root, processes can gain privileges via setuid binaries or `capability`-aware programs. The `no-new-privileges` flag prevents all privilege escalation:

```bash
docker run --security-opt=no-new-privileges --user 10001 myapp
```

```yaml
# Kubernetes equivalent
securityContext:
  runAsUser: 10001
  runAsGroup: 10001
  allowPrivilegeEscalation: false
```

What `no-new-privileges` prevents:
- `sudo` and `su` (requires setuid)
- `setuid` binary exploitation
- Linux `execve` gaining new capabilities via `ambient` capability set
- Kernel privilege escalation via user namespaces

The kernel enforces this by setting the `NO_NEW_PRIVS` flag on the process's `task_struct`, which the kernel checks before granting any privilege increase via `execve()`.

## Port Binding Implications

Non-root users cannot bind to ports below 1024 (privileged ports). The kernel enforces this via `CAP_NET_BIND_SERVICE` in the default capability set for root only.

### Problem: Non-root can't bind port 80

```dockerfile
FROM node:20-slim
RUN useradd -m appuser
USER appuser
EXPOSE 80
CMD ["node", "server.js"]
# Error: listen EACCES: permission denied 0.0.0.0:80
```

### Solution 1: Use port >= 1024

```dockerfile
EXPOSE 8080
CMD ["node", "server.js"]
```

### Solution 2: Add CAP_NET_BIND_SERVICE

```bash
docker run --cap-add=NET_BIND_SERVICE --user 10001 myapp
```

```yaml
# Kubernetes
securityContext:
  runAsUser: 10001
  capabilities:
    add: ["NET_BIND_SERVICE"]
```

### Solution 3: Port mapping at the orchestration layer

```yaml
apiVersion: v1
kind: Service
metadata:
  name: myapp
spec:
  ports:
  - port: 80
    targetPort: 8080  # Container runs on 8080
  selector:
    app: myapp
```

## Common Issues and Fixes

### Issue 1: File Permission on Volumes

When a non-root container mounts a host volume, the UID inside the container most likely doesn't match the UID on the host.

```yaml
apiVersion: v1
kind: Pod
spec:
  containers:
  - name: app
    image: myapp
    volumeMounts:
    - name: data
      mountPath: /data
  securityContext:
    runAsUser: 10001
  volumes:
  - name: data
    hostPath:
      path: /var/data
      type: DirectoryOrCreate
```

**Fix**: Set the UID on the host path, or use an `initContainer`:

```yaml
initContainers:
- name: volume-permissions
  image: busybox
  command: ["chown", "-R", "10001:10001", "/data"]
  volumeMounts:
  - name: data
    mountPath: /data
  securityContext:
    runAsUser: 0  # Needs root for chown
```

### Issue 2: Applications That Require Write Access to /tmp

Many runtimes (Node.js, Python, JVM) write to `/tmp`:

```dockerfile
FROM node:20-slim
RUN useradd -m appuser
RUN mkdir /tmp && chown 10001:10001 /tmp
USER appuser
```

For read-only filesystems, mount a tmpfs:

```yaml
volumeMounts:
- name: tmp
  mountPath: /tmp
volumes:
- name: tmp
  emptyDir:
    medium: Memory
```

### Issue 3: Applications That Require a Writable Home Directory

```dockerfile
RUN useradd -m -d /home/appuser appuser
# -m creates the home directory
ENV HOME=/home/appuser
USER appuser
```

### Issue 4: Kubernetes Pod Security Standards

Kubernetes enforces Pod Security Standards (PSS) with three levels — Privileged, Baseline, Restricted. The **Restricted** profile requires `runAsNonRoot: true`. See [Pod Security Standards](../kubernetes-security/pod-security-standards.md) for the full profile requirements and enforcement via Pod Security Admission.

## Applying Non-Root in Kubernetes

This section covers Kubernetes-specific concerns for non-root execution. For details on how securityContext fields interact across pod and container levels, see [SecurityContext vs PodSecurityContext](../kubernetes-security/securitycontext-vs-podsecuritycontext.md).

### runAsNonRoot Admission Check

Setting `runAsNonRoot: true` makes the K8s admission controller verify the container image does not run as root before admitting the pod:

| Image USER | runAsNonRoot: true | Result |
|---|---|---|
| `USER 10001` | ✅ | Admitted |
| `USER appuser` | ✅ | Admitted (resolved to UID) |
| `USER root` or `USER 0` | ❌ | Rejected |
| No USER directive (defaults to root) | ❌ | Rejected |
| `USER nobody` (UID 65534) | ✅ | Admitted (non-zero UID) |

The check reads the `Config.User` field from the image manifest. If the UID resolves to 0 or the field is empty, the pod is rejected. **This is a critical defense** because it catches cases where the Dockerfile's `USER` is removed or the base image changes.

Scenarios where `runAsNonRoot` saves you:
- Developer accidentally removes `USER` from Dockerfile — pod won't deploy
- Base image switches from Debian to Alpine with different user resolution — pod won't deploy
- Attacker swaps the image tag — admission re-checks every time

### Common Anti-Patterns

**Anti-pattern 1: Relying only on Dockerfile USER**
```yaml
# Bad — runAsNonRoot not set; a tag swap bypasses USER
securityContext:
  runAsUser: 10001
```
If someone rebuilds the image without `USER`, the pod runs as root silently.

**Anti-pattern 2: Setting runAsUser: 0**
```yaml
# Bad — explicitly runs as root, bypassing any USER directive
securityContext:
  runAsUser: 0
```
Common when debugging and accidentally left in production manifests.

**Anti-pattern 3: Not dropping ALL capabilities**
```yaml
# Bad — inherits default capabilities, many unneeded
securityContext:
  runAsNonRoot: true
```
Non-root doesn't mean capability-free. Always `drop: ["ALL"]`, then add back only what's needed.

**Anti-pattern 4: Inconsistent securityContext per container**
A pod can have 10 containers but only 2 with `runAsNonRoot: true` — the others run unrestricted. Pod-level `runAsNonRoot` prevents this.

### Admission Control and Webhooks

For enforcing non-root across your cluster, see [Admission Control](../kubernetes-security/admission-control.md). For adapting Helm charts to pass Restricted profile checks, see [Adapting Upstream Helm Charts](../kubernetes-security/adapting-upstream-helm-charts.md). For a deep dive on the companion `readOnlyRootFilesystem` setting — writable path identification, emptyDir patterns, and per-application fixes — see [Read-only Filesystems](readonly-filesystem.md).

## Complete Secure Example

```dockerfile
FROM golang:1.21 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
USER 65532:65532
EXPOSE 8080
CMD ["/app"]
```

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
spec:
  securityContext:
    runAsUser: 65532
    runAsGroup: 65532
    fsGroup: 65532
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: myapp:latest
    ports:
    - containerPort: 8080
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: tmp
      mountPath: /tmp
  volumes:
  - name: tmp
    emptyDir:
      medium: Memory
```

## Interview Tips

Know the difference between `USER` in Dockerfile and `securityContext.runAsUser` in Kubernetes — Kubernetes always overrides the Dockerfile value. Understand that `runAsNonRoot: true` makes the K8s admission controller verify the container image does not run as root (it checks the `Config.User` field in the image manifest). Be able to explain the `no-new-privileges` flag and how it interacts with `allowPrivilegeEscalation: false`. Know the Pod Security Standards' three profiles (Privileged, Baseline, Restricted) and how Pod Security Admission enforces them — see [Pod Security Standards](../kubernetes-security/pod-security-standards.md) for the full breakdown. Understand the pod vs container SecurityContext split — see [SecurityContext vs PodSecurityContext](../kubernetes-security/securitycontext-vs-podsecuritycontext.md). For adapting Helm charts to pass Restricted profile checks, see [Adapting Upstream Helm Charts](../kubernetes-security/adapting-upstream-helm-charts.md). For admission control and policy enforcement, see [Admission Control](../kubernetes-security/admission-control.md). For a deeper understanding of how the Docker engine enforces these constraints at the runtime layer, see [Docker Architecture](../docker/docker-architecture.md).
