---
title: "Container Vulnerability Scanner Internals (Trivy, Grype, Docker Scout)"
section: "CVE Lifecycle"
order: 20
---

# Container Vulnerability Scanner Internals

Modern container vulnerability scanners differ fundamentally in how they resolve dependencies, match CVEs, and present risk. Understanding these internals is critical for a Senior Supply Chain Security Engineer role at Docker — you'll need to evaluate scanners, build integrations, and explain tradeoffs to customers.

## Trivy (Aqua Security)

Trivy is the fastest widely-used scanner, optimized for CI/CD pipelines. Its architecture has two phases:

1. **SBOM extraction**: Trivy reads the filesystem layers of a container image, identifies OS package databases (`/var/lib/dpkg/status`, `/var/lib/rpm/Packages`, `/lib/apk/db/installed`) and language-specific lockfiles (`package-lock.json`, `go.sum`, `Gemfile.lock`, `Cargo.lock`, `pom.xml`).
2. **CVE matching**: It cross-references extracted package names + versions against a local vulnerability database (downloaded from `ghcr.io/aquasecurity/trivy-db`, updated every 6 hours).

Trivy resolves dependencies **heuristically** — for OS packages it uses the exact version string from the package manager. For language ecosystems, it parses the lockfile resolution graph. This means Trivy can miss vulnerabilities in transitive dependencies if only the top-level manifest is present (e.g., a `package.json` without a lockfile).

```bash
# Scan a single image
trivy image docker.io/library/node:20-alpine

# Scan with severity filter and output format
trivy image --severity CRITICAL,HIGH --format json docker.io/library/node:20-alpine

# Scan using a local Docker archive
docker save node:20-alpine -o node.tar
trivy image --input node.tar
```

Trivy's strength is speed — it decompresses layers once and processes them in a single pass. A typical scan completes in 5-15 seconds.

## Grype (Anchore)

Grype takes a deeper, library-matching approach. Instead of relying on lockfile heuristics, Grype uses **Syft** (its sibling tool) to generate a comprehensive SBOM first, then matches against Grype's vulnerability database.

```bash
# Generate SBOM, then scan
syft docker.io/library/node:20-alpine -o json > sbom.json
grype sbom.json

# Direct scan (syft runs internally)
grype docker.io/library/node:20-alpine
```

Grype's database is sourced from:
- Alpine SecDB
- Amazon Linux ALAS
- Debian Linux CVE Tracker
- GitHub Advisory Database (GHSA)
- National Vulnerability Database (NVD)
- Oracle Linux OVAL
- RedHat OVAL
- Ubuntu CVE Tracker

The key architectural difference: Grype matches CVEs using **package correlation** rather than exact version matching. It uses Syft's CPE (Common Platform Enumeration) generation to find vulnerabilities even when the exact package name doesn't match the CVE entry. This catches more vulnerabilities but produces more false positives.

```bash
# Grype with explicit CPE matching
grype docker.io/library/node:20-alpine --only-fixed
```

## Docker Scout

Docker Scout takes an **SBOM-first, policy-based** approach. It was designed to integrate with Docker Hub and Docker Desktop, providing continuous evaluation rather than point-in-time scans.

```bash
# Enable Scout on a repo
docker scout repo enable <namespace>/<repo>

# Analyze an image
docker scout quickview docker.io/library/node:20-alpine

# Full CVE listing
docker scout cves docker.io/library/node:20-alpine

# Policy evaluation
docker scout policy docker.io/library/node:20-alpine
```

Scout's architecture:
1. **SBOM generation** using Syft (same engine as Grype)
2. **SBOM upload** to Docker's backend for continuous monitoring
3. **Policy evaluation** against user-defined rules (e.g., "no critical CVEs with fix available")
4. **Diff analysis** comparing two images or an image against a baseline

Scout's differentiator is **continuous monitoring** — it stores SBOMs and re-evaluates them as new CVEs are published, without requiring a rescan.

## Comparison Table

| Feature | Trivy | Grype | Docker Scout |
|---------|-------|-------|-------------|
| Scan speed | Fastest (5-15s) | Moderate (15-30s) | Moderate + upload time |
| CVE matching | Exact version | CPE + correlation | CPE + correlation |
| False positives | Low | Medium | Low-Medium |
| False negatives | Higher (misses transitive) | Lower | Lower |
| DB update frequency | 6 hours | 4-6 hours | Real-time (server-side) |
| CI/CD native | Yes | Yes | Via Docker Hub |
| Policy engine | Via config | Via SARIF | Built-in |
| License scanning | Built-in | Via Syft | Separate |
| SBOM storage | Ephemeral | Ephemeral | Persistent |

## Scanning the Same Image: Output Comparison

```bash
$ trivy image docker.io/library/node:20-alpine | head -5
Total: 284 (UNKNOWN: 0, LOW: 12, MEDIUM: 156, HIGH: 93, CRITICAL: 23)

$ grype docker.io/library/node:20-alpine | head -5
NAME          INSTALLED      FIXED-IN     TYPE      VULNERABILITY   SEVERITY
bash          5.2.15         (no fix)     apk       CVE-2022-3715   Medium
libcrypto3    3.1.4          3.1.4-r3     apk       CVE-2023-4807   High

$ docker scout cves docker.io/library/node:20-alpine | head -5
  ✓ SBOM cached
  ✓ No vulnerable packages detected for critical severity
  ✓ 2 policies evaluated, 1 warning
```

Grype typically reports more findings than Trivy due to CPE-based matching, while Scout under-reports until its server-side database catches up with recent CVEs.

## Key Interview Points

- Trivy is best for **fast CI gatekeeping** — fail builds on critical CVEs with fixes.
- Grype is best for **deep audit** — find every possible CVE, then triage false positives.
- Docker Scout is best for **continuous compliance** — enforce policy over time, not just at build.

At Docker, you'll likely work on integrating Scout with customer workflows, improving SBOM accuracy, and building policy evaluation engines that run at scale across millions of images.

For a deeper understanding of how container image layers are constructed and stored — which directly impacts how scanners analyze them — see [Image Layers & Storage Drivers](../articles/34-image-layers-storage-drivers.md).
