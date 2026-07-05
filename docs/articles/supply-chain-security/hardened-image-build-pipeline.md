---
title: "System Design: Hardened Image Build Pipeline"
section: "Supply Chain Security Theory"
order: 8
---

# System Design: Hardened Image Build Pipeline

## Overview

Design an image build pipeline that minimizes attack surface, ensures reproducibility, and guarantees provenance. The goal is a pipeline that a security-conscious organization can trust to produce artifacts that are verifiably built from known source, with no unexpected dependencies, and signed such that tampering is detectable.

## Key Design Decisions

### Base Image Selection

The base image is the largest source of inherited CVEs. The hierarchy of trust:

1. **Distroless** — ~5 packages, no shell, no package manager, no setuid binaries. Best attack surface.
2. **Alpine** — ~30 packages, uses musl libc (fewer CVE surface than glibc historically), but ships `apk` and `sh`.
3. **Ubuntu/Debian** — ~150+ packages in the minimal variant. Convenient but large blast radius.

Pin by digest, never by tag. A tag like `ubuntu:22.04` changes over time; `ubuntu@sha256:abc123...` is immutable. Scan the pinned digest with Grype or Trivy before accepting it into the pipeline. Reject any base image exceeding configured CVE thresholds (e.g., no critical CVEs, high count < 5).

### Multi-Stage Builds

Separate builder and runtime stages:

```dockerfile
FROM golang:1.22@sha256:... AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-w -s" -o /app

FROM gcr.io/distroless/static-debian12@sha256:...
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

Each stage is scanned independently. The builder stage may contain dev tools with CVEs that never reach runtime. The runtime stage should have near-zero CVEs.

### Build Context Hygiene

- **.dockerignore** — exclude `.git`, `node_modules`, `test/`, `*.md`, CI configs. Prevents secrets in build context and reduces image size.
- **`docker build --secret`** — pass build-time secrets (NPM tokens, SSH keys) via `--secret` instead of `COPY`. Secrets never end up in image layers.
- **No `COPY .`** — copy only what's needed. `COPY go.mod go.sum ./` before `COPY . .` leverages layer caching and prevents accidental inclusion.

### SBOM Generation

Run Syft at the end of every build to generate an SBOM in SPDX or CycloneDX format:

```bash
syft packages /app -o spdx-json --file sbom.spdx.json
```

Attach the SBOM as an in-toto attestation using Cosign:

```bash
cosign attest --predicate sbom.spdx.json --type spdx $IMAGE
```

### Image Signing

Use Cosign keyless signing via OIDC (GitHub/GitLab OIDC). This binds the identity of the CI pipeline to the image digest:

```bash
cosign sign $IMAGE@$DIGEST
```

Sign the digest, not the tag. Tags are mutable; digests are immutable. Signing the digest means verification checks the cryptographic identity of the image content, not a floating label.

Also sign the SBOM and provenance attestation. This creates a bundle of cryptographically linked artifacts: image → signature → SBOM → provenance.

### Registry Hardening

Push through admission control using OPA/Gatekeeper or Kyverno. The admission policy enforces:

- Signature is present and matches expected OIDC identity (subject = CI pipeline, issuer = known provider)
- No critical CVEs in the scanned image
- Provenance attestation is present and valid (SLSA L3 predicate)

### CI/CD Integration

The pipeline is a strict sequence: **build → scan → sign → push → notify**. Each step gates the next:

```
Developer push → CI trigger → Docker build + Syft SBOM → Trivy scan →
Cosign sign + attest → OPA policy check → Registry push →
Deployment controller verifies before node pull
```

The pipeline fails on scan thresholds or signature failure. Rollback is a no-op: a failed sign means no image is pushed, and the previous image remains in the registry.

### SLSA L3 Target

- **Hermetic builds** — all dependencies declared upfront, network access disabled during build
- **Provenance generation** — in-toto attestation recording build platform, source commit, build instructions
- **Non-forgeable provenance** — build platform holds the signing key; developers never touch it

## Architecture

```
┌──────────┐    ┌──────────────┐    ┌──────────┐    ┌───────────┐
│ Developer │───▶│ CI Pipeline  │───▶│   Build  │───▶│   Scan    │
│   Push    │    │ (GitHub/     │    │ (BuildKit)│   │  (Trivy)  │
└──────────┘    │  GitLab)     │    └──────────┘   └─────┬─────┘
                └──────────────┘                          │ pass
                                                          ▼
                ┌──────────────────────────────────────────────────┐
                │         Registry Admission (OPA/Kyverno)         │
                │  ┌──────────┐  ┌──────────┐  ┌─────────────┐    │
                │  │ Signature│  │   SBOM   │  │ Provenance  │    │
                │  │ Present  │  │  Valid   │  │  SLSA L3    │    │
                │  └──────────┘  └──────────┘  └─────────────┘    │
                └──────────────────────┬───────────────────────────┘
                                       │ pass
                                       ▼
                               ┌──────────────┐
                               │   Registry   │
                               │  Push Image  │
                               └──────────────┘
                                       │
                                       ▼
                               ┌──────────────────────┐
                               │ Deployment Controller │
                               │ verify before pull    │
                               └──────────────────────┘
```

## Trade-offs

| Decision | Pro | Con |
|---|---|---|
| Distroless base | Minimal CVEs, small image | No shell — debugging requires debug container |
| Keyless signing | No key rotation, OIDC binds to pipeline | Air-gapped environments need KMS keys |
| Hermetic builds | Deterministic, auditable | Slower, breaks if upstream source disappears |
| Multi-stage | Clean separation of build vs. runtime | Complex Dockerfile, harder to maintain |

## Conclusion

A hardened image build pipeline is a layered defense: minimal base images, multi-stage separation, SBOM generation, cryptographic signing, and policy enforcement at admission. The combination of SLSA L3 provenance, Cosign keyless signing, and OPA/Kyverno admission creates a pipeline where tampering is detectable at every stage.
