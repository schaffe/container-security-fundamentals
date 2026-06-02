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

### musl vs glibc

See [musl vs glibc: Choosing a C Standard Library for Containers](29-musl-vs-glibc.md) for a full comparison of the two libc implementations and their implications for base image selection.

### Distroless vs Wolfi vs Docker Hardened Images

The attack surface table above groups Google Distroless, Chainguard Wolfi, and Docker Hardened Images (DHI, which is Wolfi-based) under "distroless-type" images. But their architectures, update models, and target users differ significantly.

#### Philosophy Comparison

| Dimension | Google Distroless | Chainguard Wolfi | Docker Hardened Images |
|-----------|------------------|-------------------|----------------------|
| **Approach** | Freeze known-good Debian packages; strip aggressively | Rebuild from source continuously; patch proactively | Wolfi base + Docker's platform layer (Hub, Scout, Build Cloud) |
| **Base system** | Debian-derived (glibc + Debian patches) | Custom-built from scratch | Wolfi (same as Chainguard) |
| **Package manager** | None in runtime | `apk` present (removable) | None in hardened variants |
| **CVE remediation** | Reactive via Debian patch cycle | Proactive within hours | Proactive (inherits Wolfi) + Docker's own CVE SLA |
| **Attestations** | Cosign signature only | SBOM + provenance + vuln scan | SBOM + provenance + vuln scan (Docker-signed) |
| **SLSA level** | Not explicitly targeted | SLSA L3 for Chainguard images | SLSA L3 |
| **FIPS 140-2/3** | Not available | Not available directly | Optional validated module |
| **Enterprise SLA** | None | Via Chainguard Enforce | Commercially supported |
| **Image catalog** | ~20 families (runtimes) | ~200+ (runtimes + middleware + databases + security) | ~25 families (curated runtimes and infrastructure) |

#### CVE Remediation Speed

This is the most important operational differentiator:

- **Distroless** depends on the Debian patch cycle: CVE disclosed → fixed in Debian unstable → propagates to stable (days to weeks) → Google rebuilds → user pulls. Typical delay: **days to weeks**. In practice, distroless carries 2-5 low-severity CVEs awaiting the Debian cycle.
- **Wolfi** bypasses distributions entirely: CVE disclosed → Chainguard applies minimal patch to Wolfi source → package rebuilt → image rebuilt → user pulls. Typical delay: **hours**.
- **DHI** inherits Wolfi's proactive patching and adds a Docker-managed SLA for critical CVEs, with automated re-scan, rebuild, and notification to subscribers.

#### Image Catalog & Attestations

Google's `gcr.io/distroless` covers runtimes only: static, base, cc, java, python, node, .NET (~20 families). No middleware or databases. Attestations are limited to a cosign signature.

Chainguard's `cgr.dev/chainguard` covers ~200+ images: runtimes, databases (PostgreSQL, Redis, MongoDB), middleware (Nginx, Envoy, HAProxy), security tools (Kyverno, Falco, OPA), monitoring (Prometheus, Grafana), and CI/CD (Tekton, ArgoCD). Every image ships with SBOM + SLSA provenance + vulnerability scan attestations. (See [Chainguard's platform strategy](28-docker-supply-chain-platform.md#chainguard) for how Wolfi, Chainguard Images, and Enforce connect.)

Docker's `docker/hardened-*` covers ~25 curated images (PostgreSQL, MongoDB, Redis, Nginx, Envoy, Grafana, Prometheus, cert-manager, Kyverno, Python, Node.js, Go, Java). Built on Wolfi, each image carries Docker-signed attestations and is distributed through Docker Hub with Scout integration.

#### Decision Framework

| Scenario | Best Choice | Why |
|----------|-------------|-----|
| Go/Rust static binary, minimal size | Distroless `static-debian12:nonroot` (~2 MB) | Smallest possible image; no deps needed |
| Go/Rust static binary + attestations | Wolfi `cgr.dev/chainguard/static` (~5 MB) | Slightly larger but includes SBOM + provenance |
| Zero CVE tolerance, any runtime | Wolfi or DHI | Proactive patching, often 0 CVEs |
| Need attestations for policy enforcement | DHI or Wolfi | Distroless lacks machine-readable attestations |
| FIPS 140-2/3 required | DHI (FIPS variant) | Only option with validated crypto modules |
| Enterprise compliance + commercial SLA | DHI | Wolfi source + Docker's SLA + Hub/Scout integration |
| Broad image catalog (databases, middleware) | Wolfi (Chainguard) | 200+ images vs ~25 DHI vs ~20 distroless |
| Custom Dockerfile, need runtime flexibility | Wolfi | `apk` available; can install tools at runtime |
| Google Cloud-native deployment | Distroless | Native GCR integration, Google-managed |

#### Relationship: Wolfi and DHI

DHI is built **on top** of Wolfi. Wolfi provides the base OS — minimal packages, proactive CVE patching, container-optimized architecture. Docker adds:
- **Distribution**: Images published to Docker Hub with verified publisher badges
- **Attestations**: Docker-signed SBOM, provenance, and vulnerability scan (Docker's keychain, not Chainguard's)
- **Scout integration**: One-click policy evaluation, environment-based recommendations
- **FIPS modules**: Validated cryptographic libraries for regulated industries
- **Commercial SLA**: Defined CVE response times, enterprise support

Chainguard and Docker compete at the platform level (Enforce vs Scout) but cooperate at the base image level (DHI uses Wolfi). This is a common pattern in open-source infrastructure — upstream supplier vs integrated platform.

See [Docker Hardened Images](26-docker-hardened-images.md) for a full breakdown of DHI's build pipeline, attestation model, and interview strategy.

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

The [Distroless vs Wolfi vs Docker Hardened Images](#distroless-vs-wolfi-vs-docker-hardened-images) section above covers the architectural differences, CVE remediation speed, attestation models, and decision framework.
