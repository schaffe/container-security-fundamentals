---
title: "Adapting Upstream Helm Charts for Hardened Environments"
section: "Helm Chart Security Adaptation"
order: 18
---

# Adapting Upstream Helm Charts for Hardened Environments

Upstream Helm charts are almost never hardened out of the box. They run as root, request broad capabilities, bind to privileged ports, and write to the container filesystem. Making them compatible with Pod Security Standards `restricted` or `baseline` requires understanding the common breaking changes — and how to fix them.

## Breaking Change 1: Container Runs as Root

**Symptom:** Pod rejected by PSA `restricted` with `runAsNonRoot: true` violation. Container crashes with `"container has runAsNonRoot and image will run as root"`.

**Root cause:** The Dockerfile uses a base image like `debian:latest` or an unmodified `golang:alpine` which defaults to UID 0.

**Fix:** Set the chart's `securityContext.runAsUser` to a non-zero UID, AND ensure the chart's image has a dedicated user. If the image has no user, use a `PodSecurityContext` with a numeric UID and ensure `/etc/passwd` entries don't break:

```yaml
securityContext:
  runAsUser: 1001
  runAsGroup: 1001
```

For images that need a user patched in at deployment, use an init container:

```yaml
initContainers:
  - name: fix-user
    image: alpine:3.18
    command:
      - sh
      - -c
      - |
        echo 'myuser:x:1001:1001::/home/myuser:/sbin/nologin' >> /etc/passwd &&
        mkdir -p /data && chown 1001:1001 /data
    securityContext:
      runAsUser: 0  # needs root for useradd
```

## Breaking Change 2: Init Containers Need NET_ADMIN

**Symptom:** Init container crashes with `"RTNETLINK answers: Operation not permitted"`.

**Root cause:** Chart uses init containers to configure iptables, set [sysctls](../linux-fundamentals/sysctl-container-security.md), or create network interfaces. Example: cert-manager's `startupapicheck` or Cilium's init container.

**Fix:** If `privileged` cannot be granted, extract the specific capability:

```yaml
# Before: init container with privileged: true
initContainers:
  - name: init
    securityContext:
      privileged: true

# After: drop privileged, add only what's needed
initContainers:
  - name: init
    securityContext:
      capabilities:
        add: ["NET_ADMIN"]
      allowPrivilegeEscalation: false
```

For `SYS_ADMIN` (e.g., mount operations), rearchitect to avoid the need entirely — mount host paths, use `emptyDir`, or move logic to a daemonset.

## Breaking Change 3: Port Binding Below 1024

**Symptom:** Container crashes with `"permission denied"` when trying to listen on port 80 or 443.

**Root cause:** The security context specifies `runAsUser: 1001` (non-root), but the application is configured to bind to port 80, 443, or another privileged port (below 1024).

**Fix:** Add `NET_BIND_SERVICE` capability, and reconfigure the app to use a high port, then use a `Service` to map:

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]
```

Better: Run the application on port 8080 internally and map with a Service:

```yaml
# values.yaml override
service:
  port: 80
  targetPort: 8080

containerPort: 8080
```

## Breaking Change 4: Volume Writes with readOnlyRootFS

**Symptom:** Container crashes with "read-only file system" errors.

**Root cause:** Chart enables `readOnlyRootFilesystem: true` (or it's enforced by PSS), but the application writes logs, cache, or temporary files to `/`, `/var/log`, or `/tmp/...` on the container filesystem.

**Fix:** Identify writable paths and mount `emptyDir` volumes. In Grafana:

```yaml
# Grafana chart adaptation
extraEmptyDirMounts:
  - name: data
    mountPath: /var/lib/grafana
  - name: plugins
    mountPath: /var/lib/grafana/plugins
  - name: tmp
    mountPath: /tmp
```

Helm template patch:

```yaml
# In deployment template
volumeMounts:
  {{- if .Values.persistence.enabled }}
  - name: storage
    mountPath: /data
  {{- end }}
  - name: tmp
    mountPath: /tmp
  - name: run
    mountPath: /var/run
volumes:
  - name: tmp
    emptyDir: {}
  - name: run
    emptyDir: {}
```

## Breaking Change 5: Liveness/Readiness Probes Using Shell

**Symptom:** Probe fails with `"exec: "/bin/sh": stat /bin/sh: permission denied"` or `"exec: "sh": stat sh: permission denied"`.

**Root cause:** The chart defines a `exec` probe that invokes a shell command (e.g., `wget`, `curl`), but `allowPrivilegeEscalation: false` and the image does not include a shell, or `readOnlyRootFilesystem` prevents it.

**Fix:** Replace `exec` probes with `httpGet` or `tcpSocket` probes:

```yaml
# Before
livenessProbe:
  exec:
    command:
      - wget
      - --spider
      - http://localhost:8080/healthz

# After
livenessProbe:
  httpGet:
    path: /healthz
    port: 8080
```

If shell is unavoidable, spawn a minimal HTTP health endpoint in the application, or use a dedicated health sidecar.

## Breaking Change 6: Privileged Containers

**Symptom:** Chart requires `privileged: true` for system-level operations.

**Root cause:** The container needs host-level access (e.g., mounting `/sys/fs/cgroup`, accessing `/dev/kmsg`, writing to [`/proc`](../linux-fundamentals/proc-container-isolation.md#attack-surface-via-proc-in-containers)).

**Fix:** Assess if `privileged` is genuinely necessary. Many cases can be replaced:
- Mount specific host paths with `hostPath` volumes and `mountPropagation`
- Use a DaemonSet with `hostPID: true` instead of privileged
- Grant specific capabilities instead of blanket `privileged`

**Example: cert-manager cainjector**

cert-manager's cainjector historically required privileged mode for certain operations. Modern versions work without it:

```yaml
cainjector:
  securityContext:
    runAsNonRoot: true
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
```

## Breaking Change 7: Ingress Controllers with hostNetwork

**Symptom:** `nginx-ingress` or `traefik` charts fail PSA `baseline` with `hostNetwork: true`.

**Root cause:** Ingress controllers traditionally use `hostNetwork` to bind directly to host ports and see real client IPs.

**Fix:** Use `hostPort` with `externalTrafficPolicy: Local` instead:

```yaml
controller:
  hostNetwork: false
  service:
    externalTrafficPolicy: Local
  dnsPolicy: ClusterFirstWithHostNet  # retain pod DNS
```

## Real-World Example: cert-manager

cert-manager is a widely used chart that must be adapted for restricted environments:

```yaml
# values-override.yaml for cert-manager on restricted cluster
installCRDs: true

securityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 1001
  seccompProfile:
    type: RuntimeDefault

cainjector:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]

startupapicheck:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1001
    allowPrivilegeEscalation: false
    capabilities:
      drop: ["ALL"]
```

## Real-World Example: Grafana

```yaml
# Grafana restricted overrides
securityContext:
  runAsNonRoot: true
  runAsUser: 472
  fsGroup: 472
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]

extraEmptyDirMounts:
  - name: tmp
    mountPath: /tmp
  - name: data
    mountPath: /var/lib/grafana

grafana.ini:
  server:
    http_port: 8080
  paths:
    data: /var/lib/grafana
```

## General Adaptation Workflow

1. **Run the chart as-is** with PSA in `audit` mode
2. **Collect violation logs**: `kubectl get events -A
3. **Check the image**: `docker inspect <image> --format '{{.Config.User}}'`
4. **Identify writable paths**: `docker run --rm <image> find / -writable -type d`
5. **Expose needed ports above 1024**: Change app config to use 8080/8443
6. **Patch security contexts** via `values.yaml`
7. **Add emptyDir volumes** for writable paths
8. **Replace exec probes** with httpGet
9. **Test in warn mode** before enforcing
