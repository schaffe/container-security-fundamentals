---
title: "Docker Scout"
section: "Docker Product & Strategy"
order: 25
---

# Docker Scout

## Overview

Docker Scout is a supply chain security analysis platform deeply integrated into the Docker ecosystem. It provides image analysis, SBOM generation, policy evaluation, and remediation guidance across the container lifecycle. Scout is Docker's answer to the question: *"How do I know what's in my images and whether it's safe to deploy?"*

Unlike standalone scanners that produce static reports, Scout operates as a continuously updated analysis engine connected to your registries, CI/CD pipelines, and runtime environments.

---

## SBOM Generation: `docker scout sbom`

The foundation of Scout is its ability to generate Software Bill of Materials (SBOMs) in multiple formats (SPDX, CycloneDX). Scout resolves packages from OS-level (dpkg, apk, rpm) and language-level (npm, pip, go mod, maven) package managers.

### Basic SBOM Workflow

```bash
# Generate an SBOM for a local image
docker scout sbom my-app:latest

# Output in SPDX JSON format
docker scout sbom --format spdx my-app:latest > sbom.spdx.json

# Output in CycloneDX format
docker scout sbom --format cyclonedx my-app:latest > sbom.cdx.json

# Only include packages from specific layers
docker scout sbom --layers my-app:latest
```

Scout's SBOM resolution is noteworthy because it distinguishes between *known* packages (from indexed databases) and *unknown* files. This means it can report packages that package managers don't track, such as statically linked Go binaries or embedded Python wheels.

### SBOM Attestation

Scout can attach SBOMs as in-toto attestations to container images, making them verifiable artifacts stored alongside the image in the registry:

```bash
# Attach an SBOM as an attestation
docker scout sbom --attest my-app:latest

# Verify attestations
docker scout attestation inspect my-app:latest
```

This is critical for supply chain integrity — the attestation is cryptographically signed and stored in the registry's OCI manifest, not in a separate database.

---

## Vulnerability Analysis: `docker scout quickview`

The `quickview` command gives an immediate health summary:

```bash
docker scout quickview my-app:latest
```

Output includes:
- Total vulnerabilities by severity (critical, high, medium, low)
- Number of fixed vs. unfixed vulnerabilities
- Base image upgrade recommendations
- Policy compliance status

### Deep Analysis

```bash
# Full vulnerability report
docker scout cves my-app:latest

# Compare two images
docker scout compare my-app:latest my-app:v1.0.0

# Only show fixable vulnerabilities
docker scout cves --only-fixed my-app:latest
```

Scout's vulnerability matching uses multiple upstream databases (NVD, GitHub Advisory Database, Red Hat OVAL, Alpine SecDB, Wolfi) and cross-references them against the SBOM's package-to-CVE mappings.

---

## Policy Evaluation: `docker scout policy`

Scout Policies allow organizations to define gates that images must pass before deployment. Policies are evaluated against the analysis results and can be environment-specific.

### Policy Configuration

Policies are defined in YAML and can be evaluated locally or in CI:

```yaml
# .scout-policy.yaml
allow:
  critical: 0
  high: 5
  medium: unlimited
exceptions:
  - cve: CVE-2024-XXXX
    reason: "No fix available, risk accepted"
    expiry: "2025-06-01"
```

### Evaluation Commands

```bash
# Evaluate against default policy
docker scout policy my-app:latest

# Evaluate with environment-specific policy
docker scout policy --env production my-app:latest

# Evaluate against a custom policy file
docker scout policy --policy custom-policy.yaml my-app:latest

# Get remediation recommendations
docker scout recommendations my-app:latest
```

### Environment-Based Policies

Scout supports the concept of *environments* — logical groupings like `development`, `staging`, `production` — each with different policy thresholds:

```bash
# Register an environment
docker scout env create production --policy-file prod-policy.yaml

# Tag an image to an environment
docker scout env add production my-app:latest@sha256:abc123

# Auto-evaluate when tagging
docker scout policy --env production my-app:latest
```

This enables graduated security gates: development allows high-severity CVEs, staging requires fixes within SLAs, production blocks critical vulnerabilities.

---

## Integration with Docker Hub and GitHub Actions

### Docker Hub Integration

When Scout is enabled on a Docker Hub repository, every push triggers automatic analysis:

1. Image pushed to Docker Hub
2. Scout analyzes the image and generates SBOM
3. Vulnerability report is available on the Hub UI
4. Policy violations are surfaced in the repository view
5. Notifications can be sent via webhooks on policy failure

```
Docker Hub UI → Repository → "Vulnerabilities" tab → Scout report
```

### GitHub Actions Integration

```yaml
name: Docker Scout Analysis

on:
  push:
    branches: [main]

jobs:
  scout:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Login to Docker Hub
        uses: docker/login-action@v3
        with:
          username: ${{ vars.DOCKER_USER }}
          password: ${{ secrets.DOCKER_PAT }}

      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          push: true
          tags: myorg/my-app:${{ github.sha }}

      - name: Analyze with Scout
        uses: docker/scout-action@v1
        with:
          command: cves,quickview,policy
          image: myorg/my-app:${{ github.sha }}
          policy-file: .scout-policy.yaml
          only-fixed: true
          exit-on-policy-failure: true
```

The `exit-on-policy-failure` flag enables Scout to act as a CI gate — if policy violations exceed thresholds, the build fails.

---

## End-to-End Workflow

```bash
# Step 1: Build the image
docker build -t my-app:latest .

# Step 2: Generate and inspect SBOM
docker scout sbom --format spdx my-app:latest > sbom.json

# Step 3: Analyze vulnerabilities
docker scout cves my-app:latest

# Step 4: Get upgrade recommendations
docker scout recommendations my-app:latest

# Step 5: Evaluate against policy
docker scout policy my-app:latest

# Step 6: Attach SBOM attestation to image
docker scout sbom --attest my-app:latest

# Step 7: Push and let Hub analyze
docker push my-app:latest
```

---

## Strategic Analysis for Interview

### Strengths
- **Developer-native**: Works within the Docker CLI developers already use; no new tooling required
- **Continuous monitoring**: Not a point-in-time scan; Scout re-evaluates as new CVEs are published
- **Environment-aware policies**: Different gates for dev/staging/prod match real deployment pipelines
- **Attestation support**: Aligns with SLSA and in-toto standards for supply chain integrity

### Weaknesses
- **Ecosystem lock-in**: Deepest integration is with Docker Hub; third-party registry support is less mature
- **Multi-architecture complexity**: Analysis across platforms requires careful configuration
- **Policy as code maturity**: Still evolving compared to dedicated policy engines like OPA or Kyverno

### Key Differentiators
- Scout combines SBOM generation, vulnerability scanning, and policy evaluation in a single CLI
- Environment-based policies map directly to deployment stages
- Remediation recommendations are actionable (`docker scout recommendations` suggests exact `apk upgrade` / `pip install` commands)

### Likely Interview Questions
- "How does Scout differ from Trivy or Grype?" (Scout is an integrated platform with policies and environments, not just a scanner)
- "How would you enforce Scout policies across 50 microservices?" (Central policy file in monorepo or per-repo config; Hub org-level policies)
- "How does Scout handle images with multiple architectures?" (Scout analyzes each platform variant; policies apply per-variant or aggregate)
- "What happens when a new CVE is published for a package in a running image?" (Scout re-scans if integrated with Hub; webhook notifications trigger alerts)

For a deeper understanding of how images are built and how Scout integrates with the build pipeline, see [BuildKit Internals](../buildkit-internals.md) and [How Docker Builds Images](../how-docker-builds-images.md).
