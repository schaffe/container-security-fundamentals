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
/proc/self/exe
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

Know that `readOnlyRootFilesystem: true` is part of the **K8s Restricted Pod Security Standard**. Understand that most containers break with this setting initially — identifying the minimum set of writable directories is the key skill. Be able to explain why read-only filesystems prevent entire classes of container escape (write-based overlay exploits, binary injection, cron/init persistence). Understand that `emptyDir` with `medium: Memory` uses the container's memory limit, so proper resource limits are essential.
