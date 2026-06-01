---
title: "Distroless Images"
section: "Container Image Hardening"
order: 1
---

# Distroless Images

Distroless images represent the extreme end of container minimization: minimal runtime dependencies with no package manager, shell, or standard Unix utilities. Published by Google (distroless) and Chainguard (Wolfi-based), these images contain only the application and its direct runtime dependencies.

## What Distroless Images Exclude

A typical distroless image removes:

- **Shell**: No `/bin/sh`, `/bin/bash`, `/bin/dash`
- **Package manager**: No `apt`, `apk`, `yum`, or `dpkg`
- **setuid/setgid binaries**: No `sudo`, `su`, `passwd` — these binaries are removed entirely or have setuid bits stripped
- **Unix tools**: No `ls`, `cat`, `cp`, `ps`, `top`, `wget`, `curl`, `tar`, `grep`, `sed`, `awk`
- **Compilers/interpreters**: No `gcc`, `python`, `perl`, unless the application requires them
- **Libraries**: Only linked libraries the binary actually needs (`ldd` verified)

## Attack Surface Comparison

| Image Base | Package Count | Shell | Pkg Manager | setuid Binaries | CVEs (typical) |
|---|---|---|---|---|---|
| **Distroless** (gcr.io/distroless) | ~5-15 | No | No | No | 0-5 |
| **Wolfi** (Chainguard) | ~5-20 | No | apk | No | 0-2 |
| **Alpine** | ~30-50 | BusyBox sh | apk | No | 5-30 |
| **Ubuntu 22.04** | ~150-200 | bash | apt | Yes (sudo, su) | 50-200+ |

### Why Distroless Reduces CVEs

Distroless drastically reduces the vulnerability surface by:

1. **No shell**: Remote code execution (RCE) without a shell prevents privilege escalation via `bash -i` or reverse shell payloads
2. **No package manager**: Supply chain attacks via compromised package repositories are impossible within the running container
3. **Minimal libc**: Distroless images use `glibc` (or `musl` for static variants) with only essential locales and NSS modules
4. **No setuid binaries**: Kernel exploits that target setuid elevation (like CVE-2021-3156, Baron Samedit) are irrelevant

Supply chain security engineers should note: **distroless images shrink the "gift" an attacker receives after initial RCE**. If a process gets compromised, the attacker has very limited tools to pivot, escalate, or exfiltrate.

### Dockerfile: Distroless vs Alpine vs Ubuntu

```dockerfile
# === Ubuntu build (baseline) ===
FROM ubuntu:22.04 AS ubuntu-app
RUN apt-get update && apt-get install -y ca-certificates && \
    rm -rf /var/lib/apt/lists/*
COPY app /app
CMD ["/app"]

# === Alpine build (smaller but shell present) ===
FROM golang:1.21 AS build
WORKDIR /src
COPY . .
RUN go build -o /app .

FROM alpine:3.19
RUN apk add --no-cache ca-certificates
COPY --from=build /app /app
CMD ["/app"]

# === Distroless build (minimal) ===
FROM golang:1.21 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 go build -o /app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
CMD ["/app"]
```

The distroless variant uses `CGO_ENABLED=0` for a fully static binary, allowing use of the `static-debian12` base which contains only:
- `ca-certificates.crt` (from distroless bundle)
- `/etc/ssl/certs/`
- `/tmp` (empty, writable)
- The zoneinfo database (minimal)

## When Distroless Breaks

Distroless is not always the right choice. Common failure points:

### 1. Health Checks

```dockerfile
# This fails — no curl/wget in distroless
HEALTHCHECK CMD curl -f http://localhost/health || exit 1
```

**Solutions**:
- Use the `netbase` variant (`gcr.io/distroless/base`) which includes basic networking
- Embed health check logic in the application binary
- Use K8s exec probes with the debug variant

```dockerfile
FROM gcr.io/distroless/base-debian12
# base variant includes basic networking but no shell
HEALTHCHECK CMD ["/healthcheck"]
```

### 2. Debugging & Exec Access

```bash
# kubectl exec into a distroless container — no shell!
kubectl exec -it pod-name -- sh
# error: failed to exec: executable file not found
```

**Solutions**:

- **Debug images**: Distroless publishes `-debug` variants with `busybox` shell:
  ```dockerfile
  # Debug multi-stage: deploy the non-debug version
  FROM gcr.io/distroless/base-debian12:nonroot
  COPY --from=build /app /app
  ```

- **Ephemeral debug containers** (K8s 1.23+):
  ```bash
  kubectl debug -it pod-name --image=gcr.io/distroless/base-debian12:debug -- /busybox/sh
  ```

- **Sidecar containers** with shared process namespace:
  ```yaml
  spec:
    shareProcessNamespace: true
    containers:
    - name: app
      image: myapp:distroless
    - name: debug
      image: nixery.dev/shell/strace/curl/htop
      command: ["sleep", "infinity"]
  ```

### 3. Signal Handling

Distroless images use tini (a minimal init) by default in some variants. Without an init process, PID 1 in Linux has special semantics: it ignores `SIGTERM` and `SIGINT` unless explicitly handled. If the application doesn't handle these signals, `docker stop` will wait 10 seconds then `SIGKILL`.

```dockerfile
# Use the distroless/cc (C++ compatible) variant which includes tini
FROM gcr.io/distroless/cc-debian12
COPY --from=build /app /app
CMD ["/app"]
```

## Mitigation Strategies

### 1. Debug Variants for Staging Only

Distroless publishes debug images tagged `:debug` and `:nonroot-debug`. These add `busybox` for inspection:

```bash
# Pull the debug variant for staging
FROM gcr.io/distroless/base-debian12:debug
COPY --from=build /app /app
# In production, switch to :nonroot
```

### 2. Static Binaries with Minimal Distroless

For Go, Rust, Zig, or any language producing static binaries:

```dockerfile
FROM golang:1.21 AS build
WORKDIR /src
COPY . .
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags="-s -w" -o /app .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /app /app
USER 65532:65532
CMD ["/app"]
```

### 3. Nixery for Custom Minimal Images

```bash
# Build a custom minimal image with only the tools you need
# docker pull nixery.dev/shell/strace/curl
```

## Interview Tips

When asked about distroless, emphasize the **supply chain security** angle: distroless removes the "blast radius" after a compromise. Understand the trade-off between debuggability and security. Be ready to discuss monohash-based vulnerability scanning — distroless images have so few packages that scanner false positives drop dramatically.

Compare distroless to **Chainguard Wolfi images**, which take a more active approach: distroless freezes packages, while Wolfi actively rebuilds from source with minimal patches, achieving similar package counts but with faster CVE remediation.
