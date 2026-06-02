---
title: "Software Bill of Materials (SBOM)"
section: "Supply Chain Security Theory"
order: 3
---

# Software Bill of Materials (SBOM)

## Overview

A Software Bill of Materials is a nested inventory of all components, libraries, and dependencies that make up a software artifact. Think of it as the ingredients list for software. SBOMs are foundational to vulnerability management — without knowing what's in your software, you cannot know which CVEs affect you.

## SBOM Formats: CycloneDX vs. SPDX

Two standards dominate. Understanding the tradeoffs is essential for interview discussions.

### CycloneDX (OWASP)

CycloneDX is purpose-built for security use cases. It has first-class support for:

- Component metadata (purl, hashes, licenses)
- Vulnerability references
- Attestation links
- Service and component relationships
- Properties for custom annotations

```xml
<?xml version="1.0"?>
<bom xmlns="http://cyclonedx.org/schema/bom/1.6"
     serialNumber="urn:uuid:3e671687-395b-41f5-a30f-a58921a69b79"
     version="1">
  <components>
    <component type="library" bom-ref="pkg:golang/github.com/gorilla/mux@v1.8.1">
      <name>github.com/gorilla/mux</name>
      <version>v1.8.1</version>
      <purl>pkg:golang/github.com/gorilla/mux@v1.8.1</purl>
      <hashes>
        <hash alg="SHA-256">abc123...</hash>
      </hashes>
    </component>
  </components>
  <dependencies>
    <dependency ref="pkg:golang/github.com/myorg/myapp@v1.0.0">
      <dependency ref="pkg:golang/github.com/gorilla/mux@v1.8.1"/>
    </dependency>
  </dependencies>
</bom>
```

### SPDX (Linux Foundation)

SPDX originated for license compliance but now covers security. Key features:

- File-level granularity (can map each file to its license and origin)
- Package verification codes
- Extensive license expression support (SPDX-License-Identifier)
- Cross-reference documents via `ExternalDocumentRef`

```json
{
  "spdxVersion": "SPDX-2.3",
  "dataLicense": "CC0-1.0",
  "SPDXID": "SPDXRef-DOCUMENT",
  "name": "myapp-1.0.0",
  "packages": [
    {
      "SPDXID": "SPDXRef-gorilla-mux",
      "name": "gorilla/mux",
      "versionInfo": "v1.8.1",
      "packageChecksum": "SHA256: abc123...",
      "licenseConcluded": "BSD-3-Clause",
      "externalRefs": [
        {
          "referenceCategory": "PACKAGE-MANAGER",
          "referenceType": "purl",
          "referenceLocator": "pkg:golang/github.com/gorilla/mux@v1.8.1"
        }
      ]
    }
  ]
}
```

### Key Differences

| Aspect | CycloneDX | SPDX |
|---|---|---|
| Primary domain | Security | License compliance |
| Vulnerability model | Native (bom-ref → advisory) | Extension (via external refs) |
| File granularity | Optional | Foundational |
| Attestation support | First-class (in-toto statements) | Requires extension |
| Ecosystem | Container/cloud-native | Embedded/traditional |
| Tooling | Syft, Trivy, Dependency-Track | Fossology, ORT |

## Generating SBOMs

### Syft (Anchore)

Fast, focused on container images and filesystems:

```bash
# Generate CycloneDX SBOM for a container image
syft packages myapp:latest -o cyclonedx-json > sbom.cdx.json

# Generate SPDX SBOM
syft packages myapp:latest -o spdx-json > sbom.spdx.json

# Generate from a directory
syft packages dir:./dist/ -o cyclonedx-json > sbom.cdx.json

# Include specific scope
syft packages myapp:latest -o cyclonedx-json \
  --scope all-layers
```

### Trivy (Aqua)

Vulnerability scanner that also generates SBOMs:

```bash
# Generate CycloneDX SBOM
trivy image --format cyclonedx --output sbom.cdx.json myapp:latest

# Generate SPDX SBOM
trivy image --format spdx-json --output sbom.spdx.json myapp:latest

# Scan using the SBOM (same tool)
trivy sbom sbom.cdx.json --severity CRITICAL,HIGH
```

### Docker Scout

Integrated into Docker CLI:

```bash
# Generate SBOM
docker scout sbom myapp:latest

# Output as CycloneDX
docker scout sbom --format cyclonedx myapp:latest > sbom.cdx.json

# Compare with policy
docker scout policy myapp:latest
```

## Consuming SBOMs for Vulnerability Matching

SBOMs enable offline and efficient vulnerability scanning. Instead of re-analyzing binaries each time, you match package URLs (purls) against CVE databases:

```bash
# Trivy scanning via SBOM (no image needed)
trivy sbom sbom.cdx.json

# Grype scanning via Syft-generated SBOM
syft packages myapp:latest -o cyclonedx > sbom.cdx.json
grype sbom:sbom.cdx.json
```

The purl format (`pkg:golang/github.com/gorilla/mux@v1.8.1`) is the key — it provides a universal package identifier across ecosystems. Vulnerability databases index CVEs by purl, making matching deterministic.

## VEX (Vulnerability Exploitability eXchange)

A VEX document explains whether a known vulnerability actually affects a given product. This avoids noise from false positives.

```json
{
  "vex": {
    "format": "text/csv",
    "vulnerabilities": [
      {
        "id": "CVE-2024-1234",
        "status": "not_affected",
        "justification": "component_not_present",
        "impact_statement": "This CVE affects the XML parser which is not compiled in our build"
      }
    ]
  }
}
```

VEX documents pair naturally with SBOMs: the SBOM says "these components exist"; the VEX says "these vulnerabilities in those components are not exploitable in our configuration."

The `status` field can be: `not_affected`, `affected`, `fixed`, `under_investigation`.

## SBOMs vs. Attestations

This is a common interview topic. SBOMs and in-toto attestations are complementary:

| | SBOM | Attestation |
|---|---|---|
| **What** | List of ingredients | Integrity claim about a process |
| **Signed?** | Usually not required | Always signed |
| **What binds it** | The artifact digest is in the SBOM metadata | The artifact digest is the statement subject |
| **Granularity** | Per-component | Per-pipeline-step |
| **Example tool** | Syft, Trivy | cosign, `attest-build-provenance` |

In practice: a build pipeline generates an SBOM with Syft, then wraps it in an in-toto attestation with cosign attest. The attestation proves who created the SBOM and when; the SBOM provides the actual dependency inventory.

```bash
# Generate SBOM
syft packages myapp:latest -o cyclonedx-json > sbom.cdx.json

# Wrap SBOM in signed attestation
cosign attest --predicate sbom.cdx.json \
  --type cyclonedx \
  myapp@sha256:abc123
```

## Common Interview Questions

- "CycloneDX vs SPDX — when would you choose one over the other?" — CycloneDX for security-focused workflows (vulnerability tracking, attestations); SPDX for license compliance and file-level provenance
- "How do SBOMs help with vulnerability management?" — They enable purl-based CVE matching without re-scanning binaries; essential for offline or air-gapped environments
- "What's the relationship between SBOMs and VEX?" — SBOMs enumerate components; VEX explains which vulnerabilities in those components are actually exploitable
- "Should SBOMs be signed?" — Yes, ideally wrapped in an in-toto attestation so consumers can verify the SBOM's authenticity and integrity
