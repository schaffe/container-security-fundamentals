---
title: "Read-only Filesystems in Containers"
section: "Container Image Hardening"
order: 7
---

# Read-only Filesystems in Containers

A read-only root filesystem (`readOnlyRootFilesystem: true`) is one of the most effective container hardening measures. When set, the container's entire filesystem is immutable — processes cannot write to any path unless an explicit writable volume is mounted. This prevents an attacker from modifying binaries, injecting malicious scripts, writing to cron, or persisting changes after compromise.

## The Security Case for Read-Only

### What Read-Only Prevents

- **Binary replacement**: Attacker cannot overwrite `/usr/bin/app` with a trojaned version
- **Configuration tampering**: Cannot modify `/etc/app/config.yaml` at runtime
- **Malicious script injection**: Cannot write `/tmp/evil.sh` and execute it
- **Log tampering**: Cannot modify existing logs (but can write to stdout/stderr)
- **Supply chain persistence**: Cannot write startup scripts or cron entries
- **Container escape via overlayfs**: Some overlayfs vulnerabilities require write access

### Attack Scenario

Without read-only root:

```
1. RCE via HTTP request (e.g., Log4Shell)
2. Compromised process runs as root
3. echo "malicious" > /etc/ld.so.preload    ← writes to container filesystem
4. Next exec loads malicious shared library  ← persistence achieved
```

With read-only root:

```
1. RCE via HTTP request
2. Compromised process runs as root
3. echo "malicious" > /etc/ld.so.preload    ← fails: Read-only file system
4. Attacker cannot persist — must exploit in-memory only
```

The ephemeral nature of the compromise is critical: the attacker loses all access when the container restarts.

## Configuring Read-Only Filesystems

### Docker

```bash
docker run --read-only --tmpfs /tmp --tmpfs /var/run myapp
```

### Kubernetes

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: readonly-app
spec:
  containers:
  - name: app
    image: myapp
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: var-run
      mountPath: /var/run
    - name: var-log
      mountPath: /var/log
    - name: cache
      mountPath: /var/cache/nginx
  volumes:
  - name: tmp
    emptyDir:
      medium: Memory
  - name: var-run
    emptyDir: {}
  - name: var-log
    emptyDir: {}
  - name: cache
    emptyDir: {}
```

## Read-Only in the Kubernetes Security Stack

`readOnlyRootFilesystem` is one of four container-level fields that form the **Restricted Pod Security Standard**:

| Field | Purpose |
|---|---|
| `readOnlyRootFilesystem: true` | Prevent filesystem writes |
| `allowPrivilegeEscalation: false` | Prevent `no_new_privs` bypass |
| `capabilities.drop: ["ALL"]` | Remove all kernel capabilities |
| `runAsNonRoot: true` | Prevent root execution |

These work together: read-only prevents file-based persistence, no-new-privs prevents setuid-based privilege escalation, dropping capabilities limits kernel attack surface, and non-root limits blast radius. Missing any one weakens the others.

For the full context on how these fit into cluster-wide policy, see [Pod Security Standards (PSS)](../kubernetes-security/pod-security-standards.md) and [Securing the Kubernetes Runtime — Defense in Depth](../kubernetes-security/securing-kubernetes-runtime.md).

### PodSecurityContext vs SecurityContext Cascade

`readOnlyRootFilesystem` exists **only at the container level** — there is no pod-level equivalent. Each container must explicitly set it:

```yaml
spec:
  securityContext:           # Pod level — CANNOT set readOnlyRootFilesystem here
    runAsNonRoot: true
  containers:
    - name: app
      securityContext:       # Container level — readOnlyRootFilesystem belongs here
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
```

This is a common interview trap: `readOnlyRootFilesystem` cannot be inherited from the pod level. If you have 10 containers, each needs its own `readOnlyRootFilesystem: true`.

### PSA Enforcement

When a namespace is labeled `pod-security.kubernetes.io/enforce: restricted`, Pod Security Admission rejects any pod where `readOnlyRootFilesystem` is unset or `false`:

```
Error: failed to create pod: pods "myapp" is forbidden:
  violates PodSecurity "restricted:latest":
    readOnlyRootFilesystem: false
```

**What to do when the pod can't go read-only:**

1. **Exempt the namespace** via `--pod-security-admission-config-file` for monitoring, logging, and infrastructure namespaces
2. **Use `audit` mode** instead of `enforce` — track violations without blocking
3. **Add `emptyDir` mounts** for every write path the application needs
4. **Widen to `baseline`** if the app genuinely needs filesystem writes (baseline does not require `readOnlyRootFilesystem`)

### Helm Chart Integration

The idiomatic Helm pattern makes readOnlyRootFilesystem configurable without template duplication:

```yaml
# values.yaml
containerSecurityContext:
  readOnlyRootFilesystem: true
  allowPrivilegeEscalation: false
  capabilities:
    drop: ["ALL"]
  runAsUser: 1001

extraVolumeMounts: []
extraVolumes: []
```

```yaml
# deployment.yaml — volume mounts
volumeMounts:
  {{- if .Values.containerSecurityContext.readOnlyRootFilesystem }}
  - name: tmp
    mountPath: /tmp
  - name: var-run
    mountPath: /var/run
  {{- end }}
  {{- with .Values.extraVolumeMounts }}
  {{- toYaml . | nindent 8 }}
  {{- end }}
volumes:
  {{- if .Values.containerSecurityContext.readOnlyRootFilesystem }}
  - name: tmp
    emptyDir:
      medium: Memory
      sizeLimit: 64Mi
  - name: var-run
    emptyDir: {}
  {{- end }}
  {{- with .Values.extraVolumes }}
  {{- toYaml . | nindent 6 }}
  {{- end }}
```

This allows operators to opt out by toggling `readOnlyRootFilesystem: false` in values, without modifying templates.

## Mounting tmpfs for Write Locations

When the root is read-only, specific directories need writable tmpfs mounts. Common writable paths:

| Path | Why It Needs Writes | Application Examples |
|---|---|---|
| `/tmp` | General temporary files | All runtimes (JVM, Node, Python) |
| `/var/run` | PID files, Unix sockets | nginx, PostgreSQL, Redis |
| `/var/log` | Application logs | Most applications |
| `/var/cache/nginx` | Proxy cache | nginx |
| `/var/lib/mysql` | Database data | MySQL/MariaDB (use PersistentVolume instead) |
| `/run/secrets` | Runtime secrets | HashiCorp Vault sidecar |
| `/home/appuser` | User home directory | SSH, git, Python venv |
| `/dev/shm` | Shared memory | PostgreSQL |
| `/var/spool/postfix` | Mail queue | Postfix |

### Best Practices for tmpfs Mounts

```yaml
# Use Memory-backed tmpfs for runtime data that doesn't need persistence
- name: tmp
  emptyDir:
    medium: Memory    # RAM-backed, faster, no disk write
    sizeLimit: 256Mi  # Prevent memory exhaustion
```

```yaml
# Use disk-backed emptyDir for larger data
- name: var-log
  emptyDir:
    sizeLimit: 500Mi
```

## What Apps Break and How to Fix

### Application 1: nginx

nginx requires writable paths for:
- `/var/run/nginx.pid` — PID file
- `/var/cache/nginx/` — proxy cache
- `/var/log/nginx/` — access and error logs

**Fix**:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: nginx
spec:
  containers:
  - name: nginx
    image: nginx:alpine
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: nginx-run
      mountPath: /var/run
    - name: nginx-cache
      mountPath: /var/cache/nginx
    - name: nginx-logs
      mountPath: /var/log/nginx
  volumes:
  - name: nginx-run
    emptyDir: {}
  - name: nginx-cache
    emptyDir: {}
  - name: nginx-logs
    emptyDir: {}
```

Or redirect nginx logs to stdout:

```nginx
# /etc/nginx/nginx.conf
error_log /dev/stdout info;
access_log /dev/stdout;
```

### Application 2: PostgreSQL

PostgreSQL requires:
- `/var/run/postgresql/` — Unix socket directory
- `/var/lib/postgresql/data/` — database data
- `/tmp/.s.PGSQL.5432` — temporary socket
- `/dev/shm` — shared memory for parallel query execution

**Fix**:

```yaml
volumeMounts:
- name: postgres-data
  mountPath: /var/lib/postgresql/data
- name: postgres-run
  mountPath: /var/run/postgresql
- name: dshm
  mountPath: /dev/shm
volumes:
- name: postgres-data
  persistentVolumeClaim:
    claimName: postgres-pvc
- name: postgres-run
  emptyDir: {}
- name: dshm
  emptyDir:
    medium: Memory
```

### Application 3: Java/JVM Applications

JVM writes to:
- `/tmp` — HotSpot compiler, JIT cache
- `java.io.tmpdir` — can be redirected
- `/tmp/hsperfdata_*` — performance data

**Fix**:

```dockerfile
# Redirect JVM temp directory
ENV _JAVA_OPTIONS="-Djava.io.tmpdir=/tmp"
```

```yaml
volumeMounts:
- name: tmp
  mountPath: /tmp
  readOnly: false
volumes:
- name: tmp
  emptyDir:
    medium: Memory
```

### Application 4: Redis

Redis requires:
- `/data` — RDB snapshots and AOF logs
- `/tmp` — temporary files during operations

**Fix**:

```yaml
volumeMounts:
- name: redis-data
  mountPath: /data
- name: tmp
  mountPath: /tmp
volumes:
- name: redis-data
  emptyDir: {}
- name: tmp
  emptyDir:
    medium: Memory
```

## emptyDir Volumes in K8s

`emptyDir` volumes are the primary mechanism for providing writable space in read-only containers.

### Properties

```yaml
volumes:
- name: tmp
  emptyDir:
    medium: Memory      # Use tmpfs (RAM) — default is disk
    sizeLimit: 1Gi      # Limit total size — prevent DoS
```

- **Sandbox isolation**: Each pod gets its own emptyDir — containers cannot see other pods' emptyDirs
- **Ephemeral**: Contents are deleted when the pod is removed
- **Medium**: 
  - Default: disk-backed (node's filesystem) — survives container restart but not pod deletion
  - Memory: tmpfs (RAM) — faster, uses container's memory limit, lost on reboot
- **Shared between containers**: All containers in a pod can share emptyDir volumes

### EmptyDir vs hostPath

```yaml
# ❌ Avoid hostPath — security risk, binds to host filesystem
volumes:
- name: data
  hostPath:
    path: /var/data
    type: DirectoryOrCreate

# ✅ Use emptyDir for ephemeral data
volumes:
- name: data
  emptyDir:
    medium: Memory
```

## Analyzing Application Write Behavior

Before enabling read-only filesystem, identify all write paths:

```bash
# Run the application and monitor writes
docker run --rm --entrypoint sh myapp -c "strace -f -e trace=%file% -o /tmp/writes.log /usr/local/bin/app"

# Or pre-flight: check for write attempts
docker run --read-only --tmpfs /tmp myapp
# If it crashes, check stderr for "Read-only file system" errors
```

Common hidden write paths:

```bash
# NSS cache
/etc/nsswitch.conf
/var/db/mtab
# Shared memory
/dev/shm
[/proc/self/exe](../linux-fundamentals/proc-container-isolation.md#1-cve-2019-5736--procselfexe-race)
# Lock files
/var/lock/
# .cache directories
/home/appuser/.cache/
```

## Complete Hardened Example

```dockerfile
FROM node:20-slim AS build
WORKDIR /app
COPY package*.json .
RUN npm ci --only=production
COPY . .

FROM gcr.io/distroless/nodejs20-debian12:nonroot
COPY --from=build /app /app
WORKDIR /app
USER 65532:65532
CMD ["/app/dist/server.js"]
```

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hardened-app
spec:
  replicas: 3
  selector:
    matchLabels:
      app: hardened-app
  template:
    metadata:
      labels:
        app: hardened-app
    spec:
      securityContext:
        runAsNonRoot: true
        seccompProfile:
          type: RuntimeDefault
      containers:
      - name: app
        image: myapp:latest
        ports:
        - containerPort: 3000
        securityContext:
          allowPrivilegeEscalation: false
          capabilities:
            drop: ["ALL"]
          readOnlyRootFilesystem: true
          runAsUser: 65532
        volumeMounts:
        - name: tmp
          mountPath: /tmp
        - name: varrun
          mountPath: /var/run
        resources:
          limits:
            memory: "256Mi"
            cpu: "500m"
      volumes:
      - name: tmp
        emptyDir:
          medium: Memory
          sizeLimit: 64Mi
      - name: varrun
        emptyDir:
          sizeLimit: 16Mi
```

## Interview Tips

Know that `readOnlyRootFilesystem: true` is part of the **K8s Restricted Pod Security Standard**. Understand that most containers break with this setting initially — identifying the minimum set of writable directories is the key skill. Be able to explain why read-only filesystems prevent entire classes of container escape (write-based overlay exploits, binary injection, cron/init persistence). Understand that `emptyDir` with `medium: Memory` uses the container's memory limit, so proper resource limits are essential. For a deeper look at how OverlayFS implements writable upperdirs over a read-only lower layer, see [Image Layers & Storage Drivers](../docker/image-layers-storage-drivers.md).

## Interview Deep Dive

**Q:** Can `readOnlyRootFilesystem` be set at the pod level?

**A:** No. It's a container-level field in `securityContext`. There's no corresponding field in `PodSecurityContext`. Each container must set it independently. This is a common misconfiguration — setting it at the pod level has no effect.

**Q:** What happens if a container with `readOnlyRootFilesystem: true` crashes?

**A:** The crash loop continues. The container's rootfs is still read-only on restart. Fix by identifying the write path that causes the crash (use `strace` or check logs for "Read-only file system" errors) and mount an `emptyDir` at that path.

**Q:** How does `readOnlyRootFilesystem` interact with `emptyDir`?

**A:** `emptyDir` volumes are always writable regardless of the root filesystem mode. This is by design — it's how you provide write access to specific paths without relaxing the global restriction. When the root is read-only and you mount an emptyDir at `/tmp`, the container can write to `/tmp` but not to `/usr/bin` or `/etc`.

**Q:** In a multi-container pod, can one container write to a shared emptyDir while another has `readOnlyRootFilesystem: true`?

**A:** Yes. Each container has its own root filesystem mode. Container A can have `readOnlyRootFilesystem: true` and read from a shared emptyDir mounted by container B (with `readOnlyRootFilesystem: false`). The `readOnly` flag on a volume mount further restricts this per container.

**Q:** What's the performance impact?

**A:** Negligible for most applications. Overlay/overlay2 already uses a copy-on-write layer for writes — making the upperdir read-only adds an in-kernel permission check. The cost is nonexistent for read-heavy workloads. Write-heavy applications using emptyDir volumes perform identically to unrestricted containers.

**Q:** How does `readOnlyRootFilesystem` prevent CVE-2019-5736 (container escape via `/proc/self/exe`)?

**A:** CVE-2019-5736 exploited a race condition where a compromised container process overwrote `/proc/self/exe` on the host via runC. With `readOnlyRootFilesystem: true`, the container cannot write to any file, including the host binary mapped through `/proc/self/exe`. This is defense in depth: the CVE was patched in runC, but read-only rootfs would have prevented exploitation even on vulnerable versions.

**Q:** Why isn't `readOnlyRootFilesystem` part of the Baseline PSS? Why only Restricted?

**A:** Baseline is designed for general-purpose workloads where a strict read-only filesystem would break many legitimate applications (databases, caches, apps that write config at startup). Baseline prevents known privilege escalations. Restricted is for security-critical workloads where adapting to read-only is justified. The tiered approach lets teams adopt incrementally.

**Q:** What's the difference between `readOnlyRootFilesystem: true` and a read-only volume mount (`volumeMounts[].readOnly: true`)?

**A:** They operate at different layers. `readOnlyRootFilesystem` makes the entire container filesystem read-only (except mounted volumes). A read-only volume mount only prevents writes to that specific volume. You use both together: root read-only globally, individual volumes set to `readOnly: false` only where writes are needed, and shared volumes set to `readOnly: true` for other containers.
