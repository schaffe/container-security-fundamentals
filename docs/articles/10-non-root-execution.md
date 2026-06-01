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

If `myapp` is compromised, the attacker has root in the container. If they find a container escape (e.g., CVE-2019-5736 runc), they have root on the host.

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

### UID 65534 (nobody)

The `nobody` user (UID 65534) exists on all Linux distributions:

```dockerfile
FROM alpine:3.19
USER 65534
CMD ["/app"]
```

There is a significant security concern with `65534`/`nobody`: **if multiple containers share the same UID namespace, an attacker in one container can signal or interfere with processes in another container that also run as `nobody`**. Additionally, `nobody`'s home directory does not exist, which breaks applications that require a writable home.

**Recommendation**: Use a dedicated UID (10001) rather than 65534.

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

Know the difference between `USER` in Dockerfile and `securityContext.runAsUser` in Kubernetes — Kubernetes always overrides the Dockerfile value. Understand that `runAsNonRoot: true` makes the K8s admission controller verify the container image does not run as root (it checks the `USER` instruction in the image config). Be able to explain the `no-new-privileges` flag and how it interacts with `AllowPrivilegeEscalation: false`.
