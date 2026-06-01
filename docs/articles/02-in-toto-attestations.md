---
title: "In-toto Attestations"
section: "Supply Chain Security Theory"
order: 2
---

# In-toto Attestations

## Overview

In-toto is a framework for securing the integrity of software supply chains. It defines a standard attestation format — a signed statement binding a **subject** (what was built) to a **predicate** (how it was built, tested, reviewed, scanned).

Attestations are the concrete data structure that enables frameworks like SLSA. When a build pipeline says "provenance is attached to this artifact," it means an in-toto attestation has been created.

## The Attestation Bundle Format

An in-toto attestation has three layers, nested like Russian dolls:

```
┌──────────────────────────────────────┐
│           DSSE Envelope              │
│  ┌────────────────────────────────┐  │
│  │     in-toto Statement          │  │
│  │  ┌──────────────────────────┐  │  │
│  │  │       Predicate          │  │  │
│  │  │  (e.g., SLSAProvenance)  │  │  │
│  │  └──────────────────────────┘  │  │
│  └────────────────────────────────┘  │
│  Base64-encoded signature(s)        │
└──────────────────────────────────────┘
```

### DSSE (Dead Simple Signing Envelope)

The outermost layer is a DSSE envelope. It wraps arbitrary payload content with one or more signatures. DSSE is format-agnostic about the payload — it can be a JSON in-toto statement, a binary blob, or any other content.

```json
{
  "payloadType": "application/vnd.in-toto+json",
  "payload": "<base64-encoded-statement>",
  "signatures": [
    {
      "keyid": "",
      "sig": "<base64-encoded-signature>"
    }
  ]
}
```

### In-toto Statement

The middle layer is the in-toto Statement, a standard wrapper:

```json
{
  "type": "https://in-toto.io/Statement/v1",
  "subject": [
    {
      "name": "myapp",
      "digest": {
        "sha256": "abcdef123456..."
      }
    }
  ],
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": { }
}
```

The `subject` array identifies the artifact(s) by digest. Every attestation must include at least one subject — that's what the attestation is _about_.

### Predicate

The innermost layer is the predicate — the domain-specific payload. In-toto defines several standard predicate types.

## Predicate Types

### SLSA Provenance (v0.2 and v1)

The most common predicate. Describes how an artifact was built. v0.2 is the original; v1 (alias `SLSAProvenanceV1`) adds support for `sourceTags`, `buildConfig`, and better hermetic build descriptions.

v1 example:

```json
{
  "predicateType": "https://slsa.dev/provenance/v1",
  "predicate": {
    "buildDefinition": {
      "buildType": "https://actions.github.io/buildtypes/workflow/v1",
      "externalParameters": {
        "workflow": {
          "ref": "refs/heads/main",
          "repository": "https://github.com/myorg/myapp"
        }
      },
      "internalParameters": null,
      "resolvedDependencies": [
        {
          "uri": "git+https://github.com/myorg/myapp@v1.2.3",
          "digest": {
            "sha1": "abc123def456"
          }
        }
      ]
    },
    "runDetails": {
      "builder": {
        "id": "https://github.com/actions/runners/2.315.0"
      },
      "metadata": {
        "invocationId": "1234567890"
      }
    }
  }
}
```

### Test Result Predicate

Documents test execution results. Useful for gates — a deployment policy can require a passing test result attestation before promoting an artifact.

```json
{
  "predicateType": "https://slsa.dev/test-result/v1",
  "predicate": {
    "subject": [
      {
        "name": "myapp",
        "digest": { "sha256": "..." }
      }
    ],
    "testType": "https://github.com/myorg/test-suites/unit/v1",
    "passed": true,
    "metadata": {
      "testFramework": "go test",
      "testCount": 142,
      "failureCount": 0
    }
  }
}
```

### Vulnerability Scan Predicate

Documents that a specific artifact digest was scanned for CVEs at a point in time. Critical for gating deployments on vulnerability thresholds.

```json
{
  "predicateType": "https://cosign.sigstore.dev/attestation/v1",
  "predicate": {
    "data": {
      "scan_results": [
        {
          "vulnerability": "CVE-2024-1234",
          "severity": "HIGH",
          "fixedIn": "libfoo 1.2.3"
        }
      ],
      "image": "myapp@sha256:..."
    }
  }
}
```

### Code Review Predicate

Documents that a specific commit was reviewed. In SLSA L4 scenarios, this proves two-person review occurred.

```json
{
  "predicateType": "https://in-toto.io/attestation/code-review/v1",
  "predicate": {
    "reviewer": {
      "sub": "alice@example.com",
      "type": "email"
    },
    "commit": "abc123...",
    "approvedAt": "2025-12-01T10:00:00Z"
  }
}
```

## Creating Attestations with cosign

The cosign CLI is the most common tool for creating in-toto attestations:

```bash
# Attest with SLSA provenance predicate
cosign attest --predicate build.provenance \
  --type slsaprovenance \
  --key cosign.key \
  myapp@sha256:abc123

# Attest with a custom predicate type
cosign attest --predicate vuln-scan.json \
  --type vuln \
  --key cosign.key \
  myapp@sha256:abc123

# Keyless attest (uses Fulcio + Rekor)
cosign attest --predicate build.provenance \
  --type slsaprovenance \
  myapp@sha256:abc123
```

The output is an in-toto attestation wrapped in a DSSE envelope, stored as an OCI artifact attached to the container image.

## Verifying Attestations

```bash
cosign verify-attestation --type slsaprovenance \
  --key public-key.pem \
  myapp@sha256:abc123

# Keyless verification
cosign verify-attestation --type slsaprovenance \
  myapp@sha256:abc123
```

The `--type` flag filters predicates — you can require a specific predicate type to be present and valid before trusting an artifact.

## Link to SLSA

SLSA provides the _requirements_; in-toto provides the _format_. Specifically:

- SLSA demands "non-forgeable provenance" at L3+ — in-toto's DSSE envelope + signature provides non-forgeability
- SLSA demands specific provenance fields (builder ID, source URI, build config) — in-toto's `SLSAProvenanceV1` predicate models these fields
- SLSA demands two-person review at L4 — in-toto's `CodeReviewV1` predicate documents the review

Without in-toto, SLSA requirements would have no standardized data model. Without SLSA, in-toto attestations would have no requirements to enforce.

## Common Interview Questions

- "What's inside an in-toto attestation?" — A DSSE envelope wrapping an in-toto statement wrapping a predicate, all signed
- "Can multiple predicates attach to the same artifact?" — Yes, you can have separate attestations for provenance, vuln scan, and test results, all referencing the same subject digest
- "How does in-toto differ from TUF?" — TUF deals with metadata freshness and key rotation for repositories; in-toto deals with per-artifact provenance and attestation across the build pipeline
