---
title: "Sigstore (cosign, Fulcio, Rekor)"
section: "Supply Chain Security Theory"
order: 4
---

# Sigstore (cosign, Fulcio, Rekor)

## Overview

Sigstore is a Linux Foundation project that makes cryptographic software signing accessible by replacing traditional long-lived key pairs with **ephemeral, OIDC-based certificates**. It consists of three core services plus a client CLI:

- **cosign** — CLI client for signing and verifying container images, blobs, and in-toto attestations
- **Fulcio** — Certificate Authority that issues short-lived code-signing certificates via OIDC
- **Rekor** — Append-only transparency log that records all signing events

The architecture eliminates the two hardest problems in code signing: **key management** (what to do with the private key) and **identity revocation** (how to invalidate a compromised key).

## cosign: Sign, Verify, Attest

### Signing

```bash
# Traditional key-based signing
cosign generate-key-pair
cosign sign --key cosign.key myorg/myapp:latest

# Keyless signing (default for newer versions)
cosign sign myorg/myapp:latest
```

Keyless signing flow:

1. cosign prompts the user to authenticate via an OIDC provider (GitHub, Google, Microsoft)
2. cosign generates an ephemeral key pair in memory
3. cosign sends the public key to Fulcio, which issues a short-lived X.509 certificate bound to the OIDC identity
4. cosign signs the artifact, attaching both the signature and the Fulcio-issued certificate
5. cosign uploads the signing metadata to Rekor, getting back a transparency log entry index

```bash
# Sign with specific OIDC provider
cosign sign --identity-token "$(gcloud auth print-identity-token)" \
  myorg/myapp:latest
```

### Verifying

```bash
# Key-based verification
cosign verify --key cosign.pub myorg/myapp:latest

# Keyless verification
cosign verify myorg/myapp:latest

# Verify with specific identity
cosign verify --certificate-identity "alice@example.com" \
  --certificate-oidc-issuer "https://accounts.google.com" \
  myorg/myapp:latest
```

Keyless verification works by:

1. Extracting the Fulcio certificate from the container image
2. Validating the certificate chain against Fulcio's root CA
3. Checking the Rekor transparency log to ensure the signing event was recorded
4. Optionally verifying the signer's identity (email, OIDC issuer)

### Attesting

```bash
# Attest with in-toto predicate
cosign attest --predicate build.provenance \
  --type slsaprovenance \
  myorg/myapp:latest

# Verify attestation
cosign verify-attestation --type slsaprovenance \
  myorg/myapp:latest
```

`cosign attest` wraps the predicate in an in-toto statement, signs the DSSE envelope, and attaches it to the container image as an OCI artifact.

## Fulcio: Ephemeral Certificate Authority

Fulcio issues X.509 certificates that are:

- **Short-lived** (typically 10–60 minutes) — no revocation list needed
- **Bound to OIDC identity** — the certificate SAN (Subject Alternative Name) contains the OIDC email or identity
- **Chained to Fulcio root** — verifiers trust Fulcio's root CA

The certificate includes custom OID extensions:

```
X509v3 extensions:
    X509v3 Subject Alternative Name:
        email:alice@example.com
    1.3.6.1.4.1.57264.1.1:
        https://accounts.google.com
    1.3.6.1.4.1.57264.1.8:
        https://github.com/myorg/myapp/.github/workflows/build.yml@refs/heads/main
```

The OID extension `1.3.6.1.4.1.57264.1.1` records the OIDC issuer. Extension `1.3.6.1.4.1.57264.1.8` records the build pipeline trigger (for CI-based signing).

## Rekor: Transparency Log

Rekor is an immutable, append-only log that records signing metadata. It provides:

- **Discovery**: Anyone can search the log to find all artifacts signed by a given identity
- **Transparency**: Signers cannot deny having signed an artifact (non-repudiation)
- **Audit**: If a signing key or identity is compromised, the log shows exactly what was signed

```bash
# Search Rekor by artifact hash
rekor-cli search --sha abc123...

# Search by email
rekor-cli search --email alice@example.com

# Get log entry details
rekor-cli get --log-index 12345678

# Verify inclusion proof
rekor-cli verify --log-index 12345678 --artifact myapp.tar.gz
```

Each Rekor entry includes an **inclusion proof** — a Merkle tree proof that the entry exists in the log at a specific index. Combined with the Signed Entry Timestamp (SET), this proves the artifact was signed before a certain time.

## Key-Based vs. Keyless Signing

| Aspect | Key-Based | Keyless (Sigstore) |
|---|---|---|
| Key storage | Filesystem, KMS, HSM | Ephemeral (never persisted) |
| Key rotation | Manual, risky | Inherent (new key per sign) |
| Identity binding | Manual (key = identity) | Automatic (via OIDC) |
| Revocation | CRL, key rotation | No revocation needed (short TTL) |
| Offline verification | Yes (with public key) | Yes (with bundle) |
| Transparency | None | Rekor log |
| Granularity | Per-key identity | Per-signer identity |

## Bundle Format for Offline Verification

Sigstore supports offline verification via **bundles** — a self-contained file with the signature, certificate, and Rekor inclusion proof.

```bash
# Create a bundle during signing
cosign sign --bundle sigstore.bundle myorg/myapp:latest

# Verify offline using the bundle
cosign verify --bundle sigstore.bundle myorg/myapp:latest
```

The bundle contains:

```json
{
  "base64Signature": "...",
  "certificate": "-----BEGIN CERTIFICATE-----...",
  "rekorBundle": {
    "signedEntryTimestamp": "...",
    "integratedTime": 1700000000,
    "logIndex": 12345678,
    "logID": "c0d23d6ad..."
  }
}
```

This enables air-gapped verification — as long as the verifier has the Rekor root public key and the bundle, they can verify offline without calling Fulcio or Rekor.

## Common Interview Questions

- "What problem does Sigstore solve that GPG signing doesn't?" — Key management: no key generation, storage, rotation, leak recovery, or revocation. Identity is bound via OIDC, so `alice@example.com` signing = `alice@example.com` verified
- "Can Sigstore work in an air-gapped environment?" — Yes, using bundles for offline verification. However, signing requires OIDC (network) unless using key-based mode
- "What happens if Rekor is unavailable?" — Signing and verification work independently; Rekor only provides transparency. Without Rekor, you lose non-repudiation and audit trails but can still verify signatures using the certificate chain
- "How does Fulcio know the OIDC token is valid?" — Fulcio validates the OIDC token's signature against the provider's JWKS endpoint, then extracts the identity into the certificate SAN
