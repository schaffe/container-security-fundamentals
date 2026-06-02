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

If `myapp` is compromised, the attacker has root in the container. If they find a container escape (e.g., [CVE-2019-5736 runc](../articles/30-docker-architecture.md#cves)), they have root on the host.

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

**Caveat — same UID across containers is the same problem as nobody**: If every container in your cluster runs as UID 10001, the cross-container signaling risk ([`/proc/PID` access](../articles/37-proc-container-isolation.md#the-kernel-access-check), `kill`, `ptrace`) is identical to using `nobody`. The UID number itself does not provide isolation — only **unique UIDs per workload** or **user namespaces** do. See [User Namespaces](#user-namespaces) below.

### UID 65534 (nobody)

The `nobody` user (UID 65534) exists on all Linux distributions:

```dockerfile
FROM alpine:3.19
USER 65534
CMD ["/app"]
```

The concerns with `nobody` are best understood in two categories:

**1. Shared-UID risk (applies to any reused UID)**: If multiple containers share the same UID, an attacker in one container can signal or interfere with processes in another — via [`/proc/PID` access](../articles/37-proc-container-isolation.md#the-kernel-access-check), `kill`, or `ptrace`. This is not specific to `nobody`; it applies equally to any UID (including 10001) used across multiple containers.

**2. `nobody`-specific issues**:
- **No home directory**: `nobody`'s home is typically `/nonexistent` or unset. Many runtimes (JVM, Node.js, Python, SSH) require a writable `$HOME` for caches, temp files, or config.
- **System daemon conflict**: `nobody` is already used by NFS, systemd-mapped services, and other kernel-managed tasks. Using it for an app creates ambiguity — is that process your app or a system daemon?
- **Unpredictable permissions**: Some kernels and distributions assign `nobody` special treatment in unprivileged user namespaces, leading to inconsistent behavior.

### User Namespaces

Neither `nobody` nor a dedicated UID provides cross-container isolation on their own. **User namespaces** do. With `--userns-remap`, Docker maps each container's UID to a different host UID range:

```
Container A: UID 10001 → Host UID 100000
Container B: UID 10001 → Host UID 200000
```

Now the kernel sees different host UIDs, so [`/proc` isolation](../articles/37-proc-container-isolation.md#how-docker-virtualizes-proc-via-pid-namespaces), signal delivery, and file permissions are enforced.

#### Not Enabled by Default

**User namespaces are OFF by default in Docker.** The container shares the host's UID namespace — the container's root is host root, and UID 10001 in the container is host UID 10001. This is why the cross-container `/proc` signaling risk is real: the kernel sees the same UID across containers.

Why off by default? User namespaces break common workflows:

| Problem | Cause | Example |
|---|---|---|
| **Volume permissions** | Container "root" maps to a high host UID, not UID 0. Host files owned by your user (UID 501) are inaccessible. | `docker run -v /home/user/data:/data` → permission denied |
| **Privileged containers** | `--privileged` doesn't grant `CAP_SYS_ADMIN` in a non-initial user namespace. Some privileged operations fail. | `--privileged` containers that manipulate kernel modules |
| **Port binding** | Binding ports <1024 needs special capability management. | `docker run -p 80:80` → permission denied |
| **Ping/ICMP** | `ping` needs `CAP_NET_RAW` in the user namespace — extra flags required. | `docker run alpine ping 8.8.8.8` → permission denied |

Docker prioritized zero-config compatibility over security by default. Every one of these breakages would generate a support ticket. Fixing them (rootless mode) took years of kernel and tooling maturation.

#### Enable in Rootful Docker

```json
// /etc/docker/daemon.json
{
  "userns-remap": "default"
}
```

This maps each container's UID 0 to a unique host range (usually starting at 100000). Docker creates `/etc/subuid` and `/etc/subgid` entries automatically with `default`.

#### Rootless Docker: The Better Path

Rootless Docker (stable since 20.10) runs the **entire daemon** as a non-root user. It enables user namespaces by default and solves the volume/network problems transparently:

| Mechanism | What It Does |
|---|---|
| **User namespaces** | Maps daemon UID → root inside containers |
| **fuse-overlayfs** | Replaces `overlay2` (needs `mount()` syscall) with FUSE filesystem — UID mapping happens in userspace |
| **slirp4netns** | Userspace network stack instead of kernel bridges and iptables — port forwarding is NAT-based |
| **dockerd-rootless-setuptool.sh** | One-command setup |

```bash
dockerd-rootless-setuptool.sh install
```

Rootless mode handles the volume permissions issue because writes go through `fuse-overlayfs`, which maps UIDs in userspace. The container's root can write to directories owned by your host user because the FUSE layer translates UIDs.

#### Kubernetes: Pod-Level User Namespaces (K8s 1.27+, beta in 1.25)

Kubernetes supports per-pod user namespaces, mapping the container's UID 0 to a non-root host UID:

```yaml
apiVersion: v1
kind: Pod
spec:
  hostUsers: false  # Enable user namespace for this pod
  containers:
  - name: app
    securityContext:
      runAsNonRoot: true
```

Note the Kubernetes securityContext `runAsUser` field (lines 95-99) sets the UID *inside* the container, not the user namespace mapping. This is orthogonal to user namespaces.

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

Kubernetes enforces Pod Security Standards (PSS) with three levels:

- **Privileged**: Unrestricted (explicit opt-in)
- **Baseline**: Minimally restrictive, prevents known escalations
- **Restricted**: Heavily restricted, follows Pod Security best practices

The **Restricted** profile requires non-root:

```yaml
securityContext:
  runAsNonRoot: true
  seccompProfile:
    type: RuntimeDefault
```

## Kubernetes SecurityContext Best Practices

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

### Pod vs Container SecurityContext

SecurityContext fields are split between pod and container level. The pod level sets defaults that containers inherit unless overridden:

| Setting | Pod level | Container level |
|---|---|---|
| `runAsUser` | ✅ (default) | ✅ (overrides) |
| `runAsGroup` | ✅ (default) | ✅ (overrides) |
| `runAsNonRoot` | ✅ only | ❌ |
| `fsGroup` | ✅ only | ❌ |
| `supplementalGroups` | ✅ only | ❌ |
| `seLinuxOptions` | ✅ (default) | ✅ (overrides) |
| `seccompProfile` | ✅ (default) | ✅ (overrides) |
| `allowPrivilegeEscalation` | ❌ | ✅ |
| `capabilities` | ❌ | ✅ |
| `readOnlyRootFilesystem` | ❌ | ✅ |

Key rules:
- `runAsNonRoot` can only be set at the pod level — it applies to all containers
- `allowPrivilegeEscalation`, `capabilities`, and `readOnlyRootFilesystem` are container-only
- The pod-level `runAsUser`/`runAsGroup` is the default; container-level overrides it

### Pod Security Admission (PSA) Enforcement

The modern way to enforce PSS is through Pod Security Admission, using namespace labels:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: latest
    pod-security.kubernetes.io/warn: restricted
    pod-security.kubernetes.io/audit: restricted
```

Three modes:
- **enforce**: Rejects pods that violate the profile
- **warn**: Admission accepts the pod but returns a warning
- **audit**: Logs violations to the audit log without interrupting admission

Best practice for adoption:
1. Start with `warn` + `audit` on `restricted` to identify violations
2. Fix workloads that fail
3. Switch to `enforce: baseline` to catch obvious issues
4. Move to `enforce: restricted` once compliant

For the Restricted profile specifically, your pod must satisfy:

| Requirement | Configuration |
|---|---|
| **Not running as root** | `runAsNonRoot: true` or image has non-root USER |
| **No privilege escalation** | `allowPrivilegeEscalation: false` |
| **Seccomp** | `seccompProfile.type: RuntimeDefault` |
| **Capabilities** | `capabilities.drop: ["ALL"]` (only `NET_BIND_SERVICE` may be added) |
| **Read-only root** | `readOnlyRootFilesystem: true` (recommended, not required) |

### Common Kubernetes Anti-Patterns

**Anti-pattern 1: Relying only on Dockerfile USER**
```yaml
# Bad — runAsNonRoot not set; a tag swap bypasses USER
securityContext:
  runAsUser: 10001
```
If someone rebuilds the image without `USER`, the pod runs as root silently. Always set `runAsNonRoot: true`.

**Anti-pattern 2: Setting runAsUser: 0**
```yaml
# Bad — explicitly runs as root, bypassing any USER directive
securityContext:
  runAsUser: 0
```
This is common when debugging ("it works locally as root") and accidentally left in production manifests.

**Anti-pattern 3: Not dropping ALL capabilities**
```yaml
# Bad — inherits default capabilities, many unneeded
securityContext:
  runAsNonRoot: true
```
Non-root doesn't mean capability-free. Always `drop: ["ALL"]`, then add back only what's needed.

**Anti-pattern 4: Inconsistent securityContext per container**
A pod can have 10 containers but only 2 with `runAsNonRoot: true` — the others run unrestricted. Pod-level `runAsNonRoot` prevents this.

### Mutating Webhooks for Non-Root Injection

When you can't control the upstream image's USER, use a mutating webhook or Kyverno policy to inject securityContext:

```yaml
# Kyverno — auto-inject runAsNonRoot into every pod
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-non-root
spec:
  rules:
  - name: auto-inject-runAsNonRoot
    match:
      any:
      - resources:
          kinds:
          - Pod
    mutate:
      patchStrategicMerge:
        spec:
          securityContext:
            +(runAsNonRoot): true
```

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

Know the difference between `USER` in Dockerfile and `securityContext.runAsUser` in Kubernetes — Kubernetes always overrides the Dockerfile value. Understand that `runAsNonRoot: true` makes the K8s admission controller verify the container image does not run as root (it checks the `USER` instruction in the image config). Be able to explain the `no-new-privileges` flag and how it interacts with `AllowPrivilegeEscalation: false`. Know the Pod Security Standards three profiles and how Pod Security Admission enforces them via namespace labels. Understand why `runAsNonRoot` at the pod level is critical — it catches tag swaps and Dockerfile regressions that a container-level `runAsUser` alone would miss. For a deeper understanding of how the Docker engine enforces these constraints, see [Docker Architecture](../articles/30-docker-architecture.md).
