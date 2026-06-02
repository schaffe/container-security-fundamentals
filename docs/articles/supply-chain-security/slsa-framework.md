---
title: "SLSA Framework (Supply-chain Levels for Software Artifacts)"
section: "Supply Chain Security Theory"
order: 1
---

# SLSA Framework (Supply-chain Levels for Software Artifacts)

## Overview

SLSA (pronounced "salsa") is a security framework from OpenSSF that defines a graduated set of supply chain integrity levels. It answers one question: **How much can you trust that a software artifact was built from the exact source and build instructions claimed?**

The framework defines four levels (L1–L4), each adding stricter requirements around provenance generation, build isolation, and reproducibility. At L4, an attacker cannot produce a signed artifact without detection even if they compromise the build platform.

## The Levels

| Requirement | SLSA L1 | SLSA L2 | SLSA L3 | SLSA L4 |
|---|---|---|---|---|
| Provenance exists | ✅ | ✅ | ✅ | ✅ |
| Provenance is authenticated | ❌ | ✅ | ✅ | ✅ |
| Provenance is non-forgeable | ❌ | ❌ | ✅ | ✅ |
| Build runs on trusted platform | ❌ | ❌ | ✅ | ✅ |
| Two-person review of changes | ❌ | ❌ | ❌ | ✅ |
| Hermetic, isolated build | ❌ | ❌ | ❌ | ✅ |
| Reproducible build | ❌ | Optional | Optional | ✅ |
| No untrusted inputs | ❌ | ❌ | ❌ | ✅ |
| Source identity in provenance | ❌ | ✅ | ✅ | ✅ |

### Level 1: Provenance Exists

The build process generates provenance documenting what was built and how. No authentication or tamper protection is required. This is the baseline — any CI pipeline that emits a build metadata file qualifies.

Example using GitHub Actions with `attest-build-provenance`:

```yaml
jobs:
  build:
    steps:
      - uses: actions/checkout@v4
      - run: make build
      - uses: actions/attest-build-provenance@v1
        with:
          subject-path: "dist/myapp.tar.gz"
```

### Level 2: Tamper-Resistant Provenance

Provenance must be **signed** and **hosted** in a location the builder controls. The build platform itself generates the signature using its own identity. This makes it detectable if someone forges provenance after the fact.

Requirements:
- Provenance is signed by the build platform (e.g., using Sigstore + OIDC)
- Provenance includes source repository and commit hash
- All build steps are recorded

Key distinction: at L2, the build platform **signs on behalf of the project**. If the build platform itself is compromised, it can issue false provenance.

### Level 3: Non-Forgeable Provenance

The build platform prevents the **developer** — not just external attackers — from tampering with the provenance. This typically means the build platform holds the signing key and refuses to sign anything it didn't execute.

Requirements:
- Build platform is hardened (isolated VMs, ephemeral environments)
- Provenance lists all source dependencies
- Build is run in a trusted control plane (e.g., Google Cloud Build, GitHub Actions hosted runners with OIDC)

At L3, even a malicious project maintainer cannot retroactively alter build provenance because they never hold the signing key.

### Level 4: Maximum Integrity

L4 adds hermetic builds, two-person review, and reproducibility. The goal: **no single compromised party can produce a malicious artifact that passes verification.**

Requirements in detail:

**Two-person review for every change:** Every source commit and every build configuration change must be reviewed by a different person than the author. In practice this means branch protection rules with `Require pull request reviews before merging` and `Dismiss stale reviews`.

**Hermetic builds:** The build must not fetch any dependencies at build time — everything is pre-declared in the provenance. Running `go build` without network access:

```bash
# Hermetic Go build — no network access
go build -mod=vendor -trimpath -ldflags="-w -s" ./...
# GOPROXY=off ensures no remote module resolution
GOPROXY=off go build ./...
```

**Reproducible builds:** Given the same source and build instructions, two independent builders produce bit-for-bit identical output. This means a third party can independently verify the build.

Go example for reproducible builds in Docker:

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-w -s -buildid=" -o /app

FROM scratch
COPY --from=builder /app /app
ENTRYPOINT ["/app"]
```

The `-trimpath` and `-buildid=` flags remove non-deterministic paths and build IDs. Setting `CGO_ENABLED=0` eliminates C compiler variation.

**No untrusted inputs:** Every dependency must itself meet SLSA L4, or the dependency is explicitly enumerated and reviewed.

## SLSA vs. In-toto

SLSA and in-toto are complementary, not competing:

- **In-toto** defines the **attestation format** (how provenance is structured and signed) and the **layout** (who is authorized to perform which steps in the pipeline)
- **SLSA** defines the **requirements** (what constitutes trustworthy provenance)

In practice: in-toto attestations carry SLSA provenance predicates. A SLSA L3+ build emits an in-toto `SLSAProvenanceV1` predicate wrapped in a DSSE envelope signed with the build platform's key. The verifier checks the predicate against SLSA requirements.

## Verification Example

Using `slsa-verifier` to check provenance:

```bash
slsa-verifier verify-artifact \
  --provenance-path build.provenance \
  --source-uri github.com/myorg/myapp \
  --source-tag v1.2.3 \
  dist/myapp.tar.gz
```

This checks: (1) provenance signature is valid, (2) source URI matches, (3) provenance claims the build was hermetic, (4) the digest matches the artifact.

## Common Interview Questions

- "What does SLSA L4 add over L3?" — Two-person review, hermetic builds, no untrusted inputs, reproducibility
- "Can an L4 build use private dependencies?" — Only if the private dependency also meets SLSA L4, or is explicitly enumerated in provenance as an expected dependency
- "Is SLSA a tool or a standard?" — Both. It's a specification with reference implementations (`slsa-github-generator`, `slsa-verifier`)
- "How does SLSA relate to in-toto?" — SLSA defines the trust requirements; in-toto defines the attestation format to meet them
- "What build tools support SLSA L3?" — [BuildKit Internals](../docker/buildkit-internals.md) covers BuildKit's SLSA L3 compliance through provenance attestations and hermetic builds
