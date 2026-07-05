---
title: "System Design: Image Signing and Verification Workflow"
section: "Supply Chain Security Theory"
order: 9
---

# System Design: Image Signing and Verification Workflow

## Overview

Design a workflow that proves an image's origin, detects tampering, and enforces policy at deployment time. The goal is to ensure that every container running in a cluster was built by an authorized CI pipeline, has not been altered since signing, and carries verifiable metadata (SBOM, provenance, SLSA attestation).

## Key Design Decisions

### Signing: Cosign Keyless via OIDC

Cosign keyless signing uses ephemeral certificates issued by Fulcio, a Sigstore component, bound to the CI pipeline's OIDC identity. No long-lived keys to rotate or store:

```bash
cosign sign $IMAGE@$DIGEST
```

**Sign the digest, not the tag.** Tags like `latest` are mutable — two different images can share the same tag. Digests are immutable content hashes. Signing the digest binds the signature to the exact image content. Verification always checks `$IMAGE@$DIGEST`.

The signature is stored as an OCI artifact in the registry alongside the image. It contains the digest, the signer's identity (OIDC subject + issuer), and the Fulcio certificate chain.

**Sign more than the image.** Also sign the SBOM (`cosign attest --predicate sbom.spdx.json --type spdx`) and provenance attestation (`cosign attest --predicate provenance.json --type slsaprovenance/v1`). Each is attached as an in-toto attestation, creating a bundle: image ↔ signature ↔ SBOM ↔ provenance. An attacker who tampers with the image must also forge the signature, the SBOM, and the provenance attestation.

### Verification at Deploy: Admission Controller

A Kubernetes admission controller (Kyverno with `verifyImages`, or Ratify) intercepts all Pod create operations. It performs three checks:

1. **Signature exists and matches expected identity** — The signature must be present and its OIDC identity must match the expected CI pipeline.
2. **Attestation contains valid SBOM** — The SBOM attestation is verified and checked for policy violations (no critical CVEs, no prohibited packages).
3. **Attestation matches SLSA level** — The provenance attestation is verified and meets the required SLSA level.

### Policy as Code: Rego Rules

An admission policy expressed in Rego (OPA/Gatekeeper):

```rego
allow if {
  input.image.registry == "trusted-registry.io"
  cosign.verify(input.image, {
    "subject": "https://github.com/myorg/myapp/.github/workflows/build.yml@refs/heads/main",
    "issuer": "https://token.actions.githubusercontent.com"
  })
  input.image.annotations["build.slsa.level"] == "3"
}
```

If any check fails, the admission controller rejects the Pod creation with a clear message.

### Key Management

**Keyless signing** eliminates key rotation for internet-connected CI. Fulcio issues short-lived certificates (minutes) bound to the OIDC token. Rekor, the Sigstore transparency log, records every signing event for audit.

**Air-gapped environments** need a different approach. Use rootless key pairs stored in a KMS:

- **AWS KMS** — `cosign generate-key-pair --kms aws-kms://arn:aws:kms:us-east-1:...`
- **GCP Cloud KMS** — `cosign generate-key-pair --kms gcpkms://projects/...`
- **Azure Key Vault** — `cosign generate-key-pair --kms azurekms://...`

The private key never leaves the KMS. Signing happens via KMS API calls.

### Continuous Verification: Ratify

Ratify is a Kubernetes admission controller that verifies the entire signature chain before the node pulls the image:

1. Checks the signature against Fulcio's certificate chain
2. Verifies the Rekor transparency log entry
3. Validates attestations (SBOM, provenance)
4. Applies policy

If verification fails, the image pull is denied. This prevents a compromised node from pulling an unsigned image even if admission was bypassed.

### Tool Comparison

| Capability | Cosign | Notary v2 | Prysm |
|---|---|---|---|
| Keyless OIDC signing | ✅ Native | ❌ TUF keys | ✅ Supported |
| Signing format | OCI artifact | OCI artifact | WASM module |
| Attestation support | ✅ In-toto attests | ❌ Sign-only | ✅ Through WASM |
| Verification | cosign verify CLI | Notation CLI | Prysm plugin |
| Transparency log | Rekor | Optional | Configurable |
| Maturity | GA, wide adoption | GA, Docker ecosystem | Beta, extensible |
| Air-gapped | KMS support | TUF delegation | WASM-based |

Cosign dominates for OIDC-based workflows because keyless signing removes the key management burden. Notary v2 fits ecosystems already using TUF. Prysm is extensible via WASM but less mature.

## Architecture

```
                     CI Pipeline
                         │
                    cosign sign
                    cosign attest
                         │
                         ▼
                  ┌──────────────┐
                  │   Registry   │
                  │  (image +    │
                  │   signature  │
                  │   + SBOM     │
                  │   + provenance)│
                  └──────┬───────┘
                         │
                         ▼
            ┌──────────────────────────┐
            │   Admission Controller   │
            │   (Kyverno/Ratify)       │
            │ 1. Verify signature      │
            │ 2. Verify attestations   │
            │ 3. Apply Rego policy     │
            │                          │
            │ pass? ──── YES ──────►   │
            │ reject ◄── NO           │
            └──────────────────────────┘
                         │
                         ▼
            ┌──────────────────────────┐
            │   Ratify (pre-pull)      │
            │   - Cert chain check     │
            │   - Rekor transparency   │
            │   - Policy evaluation    │
            └──────────────────────────┘
                         │
                         ▼
                  ┌──────────────┐
                  │    Node      │
                  │  Pull Image  │
                  │  Run Pod     │
                  └──────────────┘
```

## Trade-offs

| Decision | Pro | Con |
|---|---|---|
| Keyless signing | No key rotation, strong OIDC binding | Requires internet access (Fulcio + Rekor) |
| Sign digest, not tag | Immutable binding, tamper-proof | Tag-to-digest resolution needed at deploy |
| Ratify admission + pre-pull | Defense in depth, catches bypasses | Deploy latency from verification time |
| Rekor transparency log | Public audit trail, detects key compromise | Privacy concern — all signing events are public |

## Conclusion

An image signing and verification workflow is the enforcement layer of supply chain security. Cosign keyless signing at build time, plus verification at admission and pre-pull via Ratify, creates a chain where tampering is detectable and unsigned images cannot run. The choice between keyless and KMS-backed signing depends on connectivity; the choice between Cosign, Notary v2, and Prysm depends on the existing trust infrastructure. In all cases, the principle is the same: verify before execute, and never trust a tag.
