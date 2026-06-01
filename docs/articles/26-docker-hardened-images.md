---
title: "Docker Hardened Images (DHI)"
section: "Docker Product & Strategy"
order: 26
---

# Docker Hardened Images (DHI)

## Overview

Docker Hardened Images (DHI) are a catalog of security-hardened container images designed for enterprises with strict compliance requirements. Unlike Docker Official Images, which focus on general-purpose usability and community best practices, DHIs are built to meet the security bar required by regulated industries — FedRAMP, SOC 2, HIPAA, PCI-DSS, and SLSA L3.

Docker positions DHIs as a drop-in replacement for standard base images, where the hardening is transparent to the application developer but provides significantly stronger supply chain guarantees.

---

## Catalog Contents

DHI currently covers a focused set of high-value runtimes and infrastructure components:

| Category | Images |
|----------|--------|
| **Databases** | PostgreSQL, MongoDB, Redis |
| **Web/Proxy** | Nginx, Envoy |
| **Monitoring** | Grafana, Prometheus |
| **Security** | cert-manager, Kyverno |
| **Languages** | Python, Node.js, Go, Java (OpenJDK) |
| **Distroless** | Minimal static base, glibc-based, musl-based base images |

### Image Characteristics

Each hardened image follows the same hardening profile:

- **Non-root user by default**: Containers run as an unprivileged user (typically `65532:65532`)
- **Read-only root filesystem**: Writable paths are explicitly declared as volumes
- **Capability drop**: All capabilities removed except those explicitly required
- **No shell or package manager**: Distroless variants remove `sh`, `bash`, `apk`, `apt`, `pip`
- **Immutable tags**: Tags include the full `@sha256:` digest for reproducibility
- **Signed attestations**: In-toto attestations for SBOM, provenance, and vulnerability scan results

### Comparison: Docker Official Image vs. Hardened Image

| Attribute | Official Image | Hardened Image |
|-----------|---------------|----------------|
| Base OS | Debian, Alpine, Ubuntu | Wolfi (custom, built for security) |
| User | Varies (often root) | Non-root, fixed UID |
| Capabilities | Minimal but permissive | Strictly enumerated |
| Shell | Present (bash/sh) | Removed |
| Package manager | Present | Removed |
| CVE scanning | Periodic | Continuous, per-build |
| Attestations | None | SBOM + provenance + scan results |
| SLSA level | SLSA L1-L2 | SLSA L3 |
| Enterprise SLA | None | Commercially supported |
| FIPS 140-2/3 | Not available | Optional module |

---

## Build Pipeline

DHI's build pipeline is the engineering backbone that justifies its security claims. It is designed to meet SLSA L3 requirements:

```
Source → Build (BuildKit) → Sign (cosign) → Attest → Scan → Publish
```

### SLSA L3 Compliance

SLSA L3 requires:
1. **Provenance generation**: Build metadata (source commit, build command, builder identity) is recorded
2. **Signed provenance**: The provenance record is cryptographically signed
3. **Isolated builds**: Each build runs in a fresh, ephemeral environment
4. **Hardened builder**: The build platform enforces security controls (no network access during build, no secrets leaked)

### BuildKit and Multi-Architecture

```bash
# DHI images are built for multiple architectures simultaneously
# The build pipeline uses BuildKit with --set platform flag

# Example: building a hardened Nginx image
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --sbom=true \
  --attest type=provenance,mode=max \
  --attest type=cyclonedx \
  --output type=image,name=docker.io/docker/hardened-nginx:1.25,push=true \
  .
```

The multi-architecture manifest allows a single tag to resolve to the correct platform image:

```bash
# On an ARM Mac
docker pull docker/hardened-postgres:16
# Automatically resolves to linux/arm64

# On an AMD64 server
docker pull docker/hardened-postgres:16
# Automatically resolves to linux/amd64
```

### Cosign Signing and Attestations

Every DHI image is signed with cosign, and multiple attestation types are attached:

```bash
# Verify image signature
cosign verify \
  --key docker.pub \
  docker.io/docker/hardened-nginx:1.25

# Verify SBOM attestation
cosign verify-attestation \
  --key docker.pub \
  --type cyclonedx \
  docker.io/docker/hardened-nginx:1.25

# Verify provenance attestation
cosign verify-attestation \
  --key docker.pub \
  --type https://slsa.dev/provenance/v1 \
  docker.io/docker/hardened-nginx:1.25

# Verify vulnerability scan attestation
cosign verify-attestation \
  --key docker.pub \
  --type https://anchore.com/grype/v1 \
  docker.io/docker/hardened-nginx:1.25
```

### Regular CVE Scanning

The pipeline scans each image at build time and on a recurring schedule. Any new CVE that affects a published image triggers:

1. Automated re-scan of all affected tags
2. Severity assessment
3. Automated PR to dependency update branch (if fix available)
4. Rebuild and re-publish
5. Notification to subscribers via Docker Hub

---

## FIPS Options

For US government and regulated industry customers, DHI offers FIPS 140-2/3 validated cryptographic modules:

- FIPS-enabled variants use validated OpenSSL or BoringCrypto modules
- Images are tested against the NIST Cryptographic Algorithm Verification Program (CAVP)
- Available for select images (PostgreSQL, Nginx, OpenJDK, Go runtime)

```bash
# Pull a FIPS variant
docker pull docker/hardened-postgres:16-fips
```

The FIPS build is identical to the standard hardened image except the cryptographic library is the validated module. Application code does not need modification.

---

## Typical Customer Use Cases

### Regulated Industries

- **Financial services**: SOC 2 compliance requires foundation images with known provenance, no root processes, and auditable build pipelines
- **Healthcare**: HIPAA security rule §164.312(a)(1) requires access controls; non-root containers with read-only filesystems align with this requirement
- **Government**: FedRAMP requires FIPS 140-2/3 validated cryptography for all data at rest and in transit
- **Defense/Contractors**: NIST SP 800-53 and CMMC require supply chain risk management; SLSA L3 attestations provide auditable evidence

### Enterprise Security Programs

- **Vulnerability management**: Immutable tags and attested SBOMs allow security teams to inventory every package in production
- **Incident response**: When a CVE is published, the security team can query which images contain the affected package using Scout
- **Audit readiness**: Provenance attestations serve as evidence for internal and external auditors

---

## Strategic Analysis for Interview

### Differentiators from Docker Official Images

The key question an interviewer might ask: *"Why not just use the official Nginx image?"*

- **Attack surface reduction**: Official images include shells, package managers, and often run as root. DHI removes all of these by default.
- **Attestation chain**: Official images don't carry signed SBOM or provenance attestations. DHI images ship with verifiable metadata attached.
- **SLA commitment**: DHI is backed by a commercial SLA; official images are community-maintained.
- **FIPS**: Official images don't offer FIPS-validated cryptographic modules.
- **CVE response SLA**: DHI has a defined SLA for CVE remediation; official images rely on community patch cycles.

### Competitive Positioning

DHI competes with:
- **Chainguard Images**: Similar concept (Wolfi-based, hardened, distroless). Differentiators: Docker offers tighter integration with Docker Hub, Scout, and Build Cloud. Chainguard has a broader language/image catalog and deeper Wolfi expertise.
- **Red Hat UBI**: Mature, well-supported, RHEL-based. Differentiator: DHI is distribution-agnostic, lighter weight, and doesn't require a RHEL subscription.
- **Google distroless**: Minimal but not hardened to the same degree (no non-root default, no signed attestations). Differentiator: DHI adds the hardening layer Google leaves to the consumer.

### Likely Interview Questions

- "When would you choose DHI over building your own hardened base image?" (When you want attestations, SLSA L3, and ongoing CVE scanning without maintaining a custom build pipeline)
- "How do you verify that a DHI image hasn't been tampered with?" (cosign verify + verify-attestation against Docker's public key)
- "What's the upgrade path for a team using official Postgres moving to DHI Postgres?" (Generally transparent — same env vars, same ports, same data directory structure; non-root may require changes to init scripts)
- "How does Docker handle zero-day CVEs for DHI images?" (Automated re-scan, assessment, rebuild, publish, notification within defined SLA)
