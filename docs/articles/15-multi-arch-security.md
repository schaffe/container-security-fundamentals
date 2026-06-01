---
title: "Multi-architecture Container Security"
section: "Container Image Hardening"
order: 8
---

# Multi-architecture Container Security

Multi-architecture container images ensure that a single image reference (e.g., `myapp:v1.0`) automatically works on different CPU architectures — amd64, arm64, armv7, s390x, ppc64le. While multi-arch is a deployment convenience, it introduces significant supply chain security considerations that a Senior Supply Chain Security Engineer must understand.

## The Multi-Architecture Manifest

Container registries support multi-architecture images through the OCI Image Index (also called a manifest list):

```json
{
  "schemaVersion": 2,
  "mediaType": "application/vnd.oci.image.index.v1+json",
  "manifests": [
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:amd64-digest",
      "platform": {
        "architecture": "amd64",
        "os": "linux"
      }
    },
    {
      "mediaType": "application/vnd.oci.image.manifest.v1+json",
      "digest": "sha256:arm64-digest",
      "platform": {
        "architecture": "arm64",
        "os": "linux",
        "variant": "v8"
      }
    }
  ]
}
```

```bash
# Inspect the multi-arch manifest
docker manifest inspect myapp:v1.0

# Or with crane
crane manifest myapp:v1.0

# List all architectures in an image
docker buildx imagetools inspect myapp:v1.0
```

## FROM --platform=$BUILDPLATFORM

The modern approach to multi-arch builds uses Docker BuildKit's built-in platform variables:

```dockerfile
# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM golang:1.21 AS builder
ARG TARGETOS
ARG TARGETARCH

WORKDIR /src
COPY . .
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 \
    go build -ldflags="-s -w" -o /app .

FROM gcr.io/distroless/static-debian12:nonroot-${TARGETARCH}
COPY --from=builder /app /app
USER 65532:65532
CMD ["/app"]
```

Build for multiple architectures:

```bash
# Create a builder instance
docker buildx create --use --name multiarch

# Build and push all architectures
docker buildx build \
  --platform linux/amd64,linux/arm64,linux/arm/v7 \
  -t myapp:v1.0 \
  --push .
```

### Platform Variables Available During Build

| Variable | Example Value | Description |
|---|---|---|
| `BUILDPLATFORM` | `linux/amd64` | The platform running the build |
| `BUILDOS` | `linux` | OS of the build host |
| `BUILDARCH` | `amd64` | Architecture of the build host |
| `TARGETPLATFORM` | `linux/arm64` | The platform being built for |
| `TARGETOS` | `linux` | OS of the target |
| `TARGETARCH` | `arm64` | Architecture of the target |
| `TARGETVARIANT` | `v8` | Architecture variant (arm v7/v8) |

## Per-Architecture Base Image CVE Profiles

**Different architectures have different CVE profiles**. This is a critical supply chain consideration:

| Architecture | Base Image | Typical CVE Count (Distroless Static) | Notes |
|---|---|---|---|
| **amd64** | gcr.io/distroless/static-debian12:nonroot | ~5 | Most widely scanned, quickest CVE remediation |
| **arm64** | gcr.io/distroless/static-debian12:nonroot-arm64 | ~5 | Similar to amd64, same packages |
| **arm/v7** | gcr.io/distroless/static-debian12:nonroot-arm | ~8 | Older glibc snapshot, fewer patches |
| **s390x** | gcr.io/distroless/static-debian12:nonroot-s390x | ~12 | Architecture receives fewer backport fixes |
| **ppc64le** | gcr.io/distroless/static-debian12:nonroot-ppc64le | ~10 | Similar delay in security patches |

### Why Architecture Affects CVEs

1. **Package rebuild frequency**: Debian and other distros rebuild packages per-architecture. A CVE fixed for amd64 on day 1 may take days or weeks to land for arm/v7 or s390x.

2. **Binary-only packages**: Some vendor-provided binaries (e.g., NVIDIA CUDA, Intel MKL) are only available for specific architectures, requiring alternative packages with different CVE profiles.

3. **Compiler-specific vulnerabilities**: CVEs in GCC, LLVM, or architecture-specific code (e.g., ARM TrustZone, AMD SEV) affect only certain platforms.

4. **Rare architecture delays**: s390x and ppc64le have fewer maintainers, leading to delayed CVE backports.

### Auditing Per-Architecture CVEs

```bash
# Scan each architecture separately
docker scan myapp:v1.0 --platform linux/amd64
docker scan myapp:v1.0 --platform linux/arm64

# With Grype
grype myapp:v1.0 --platform linux/amd64
grype myapp:v1.0 --platform linux/arm64

# With Trivy
trivy image --platform linux/amd64 myapp:v1.0
trivy image --platform linux/arm64 myapp:v1.0
```

### Generating Per-Architecture SBOMs

```bash
# Generate SBOM per architecture
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --attest type=sbom,generator=cylindrical/docker-sbom \
  -t myapp:v1.0 \
  --push .

# Download SBOM for a specific platform
crane manifest myapp:v1.0@sha256:amd64-digest > manifest.json
crane blob myapp:v1.0@sha256:sbom-blob-digest > sbom.spdx.json
```

## Registries with Multi-Arch Manifests

### OCI Distribution Spec Support

| Registry | Multi-Arch Support | Attestation Support | Notes |
|---|---|---|---|
| **Docker Hub** | Full | Via annotations | Requires `--push` with buildx |
| **Google Artifact Registry** | Full | Native (SLSA, SPDX) | Integrated with Binary Authorization |
| **Amazon ECR** | Full | Via OCI artifacts | Signature via Signer |
| **Azure ACR** | Full | Via OCI artifacts | Integrated with Notation |
| **GitHub Container Registry** (ghcr.io) | Full | Via OCI artifacts | OIDC-based signing |
| **Harbor** | Full | Via Cosign integration | Supports replication per-arch |

### Pushing Multi-Arch Images

```bash
# Build and push multi-arch
docker buildx build --platform linux/amd64,linux/arm64 -t myapp:v1.0 --push .

# Or create manifest list manually
docker manifest create myapp:v1.0 \
  myapp:v1.0-amd64 \
  myapp:v1.0-arm64

docker manifest push myapp:v1.0
```

## Attestations per Architecture

Attestations provide cryptographic proof about an image's origin, build process, and vulnerability status. With multi-arch, attestations must be generated and signed per architecture.

### Cosign Attestations per Architecture

```bash
# Build with SBOM and provenance attestations per architecture
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --attest type=sbom \
  --attest type=provenance,mode=max \
  -t myapp:v1.0 \
  --push .

# Sign each architecture's manifest
cosign sign myapp:v1.0@sha256:amd64-digest
cosign sign myapp:v1.0@sha256:arm64-digest

# Verify signatures for a specific platform
cosign verify \
  --key cosign.pub \
  myapp:v1.0@sha256:amd64-digest

# Policy: only deploy if both architectures verified
cosign verify \
  --policy policy.json \
  myapp:v1.0
```

### SLSA Provenance per Architecture

```json
{
  "subject": [
    {
      "name": "myapp:v1.0",
      "digest": {
        "sha256": "amd64-specific-digest"
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "builder": { "id": "https://github.com/actions/runner" },
    "buildType": "https://docker.io/buildx/build/v1",
    "invocation": {
      "configSource": {
        "uri": "git+https://github.com/myorg/myapp@refs/tags/v1.0",
        "digest": { "sha1": "abc123def456" }
      }
    },
    "buildConfig": {
      "platforms": ["linux/amd64", "linux/arm64"],
      "targetPlatform": "linux/amd64"
    },
    "metadata": {
      "buildStartedOn": "2026-05-20T10:00:00Z",
      "completeness": {
        "environment": true,
        "parameters": true,
        "materials": true
      }
    }
  }
}
```

## Cross-Build Security Concerns

### 1. Emulation-Based Builds (QEMU)

When building for `arm64` on an `amd64` host, Docker uses QEMU user-mode emulation:

```bash
# Install QEMU binfmt support
docker run --privileged --rm tonistiigi/binfmt --install all

# Now builds can cross-compile via QEMU emulation
docker buildx create --use --name multiarch
```

**Security risks of QEMU emulation**:
- QEMU user-mode emulation has a history of VM escape CVEs (CVE-2020-25704, CVE-2021-20255)
- Emulation runs the entire build pipeline — package downloads, compilation, tests — in an emulated environment
- Supply chain attacks targeting emulation bugs could compromise the build host

**Mitigation**: Prefer native cross-compilation over QEMU emulation:

```dockerfile
# Use native cross-compilation for Go
FROM --platform=$BUILDPLATFORM golang:1.21 AS builder
ARG TARGETOS TARGETARCH
# Cross-compiles natively — no QEMU needed
RUN GOOS=$TARGETOS GOARCH=$TARGETARCH CGO_ENABLED=0 go build -o /app .
```

### 2. Architecture-Specific Dependency Attacks

A malicious package may behave differently on different architectures:

```toml
# Cargo.toml — benign but arch-specific vulnerability
[dependencies]
# On amd64, this compiles to safe code
# On arm64, unsafe vector instructions expose a buffer overflow
arch-specific-crate = "1.0"
```

**Mitigation**: Scan dependencies per architecture with tooling that understands arch-specific compilation:

```bash
# Run security audit per architecture
cargo audit --target aarch64-unknown-linux-gnu
cargo audit --target x86_64-unknown-linux-gnu
```

### 3. Hash Mismatch Across Architectures

Each architecture produces a different image digest. This complicates:
- **Image pinning**: Pinning to `myapp@sha256:amd64-digest` won't work on arm64 nodes
- **Admission control**: Must verify all architecture digests, not just the one on the container registry's index

**Solution**: Pin to the manifest list digest, not individual architecture digests:

```yaml
# ✅ Correct: pin to the manifest list digest
image: myapp@sha256:manifest-list-digest
# Kubernetes will resolve to the correct architecture from the list

# ❌ Wrong: pinning to amd64 digest breaks arm64 nodes
image: myapp@sha256:amd64-specific-digest
```

### 4. CI/CD Pipeline Complexity

```yaml
# GitHub Actions multi-arch build with security scanning
jobs:
  build:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        platform: [linux/amd64, linux/arm64]
    steps:
    - uses: actions/checkout@v4
    - uses: docker/setup-buildx-action@v3
    - name: Build and scan
      uses: docker/build-push-action@v5
      with:
        platforms: ${{ matrix.platform }}
        tags: myapp:${{ github.sha }}-${{ matrix.platform }}
    - name: Scan
      run: |
        trivy image myapp:${{ github.sha }}-${{ matrix.platform }}
        cosign sign myapp:${{ github.sha }}-${{ matrix.platform }}
    - name: Create manifest list
      run: |
        docker manifest create myapp:latest \
          myapp:${{ github.sha }}-linux/amd64 \
          myapp:${{ github.sha }}-linux/arm64
        docker manifest push myapp:latest
```

## Interview Tips

Multi-arch security is an evolving area. Understand that most vulnerability scanners default to amd64 — you must explicitly specify the target platform. Know that SBOM and provenance attestations should be generated per architecture, not just for the manifest list. Be able to discuss the trade-off between QEMU emulation and native cross-compilation for security. Understand that arm64's growing popularity means CVE response times are rapidly converging with amd64 (but s390x/ppc64le remain slower).
