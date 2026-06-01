---
title: "Trusted Builds"
section: "Supply Chain Security Theory"
order: 6
---

# Trusted Builds

## Overview

A trusted build is one where the output cannot be tampered with after the build completes — and where the build platform's identity is **independently verifiable**. The core principle: **the build platform proves it executed the build; the build platform's key signs the output.**

This means an attacker who compromises source control, a developer workstation, or even a non-build CI job cannot produce a signed artifact that passes verification.

## The Non-Build Platform Cannot Sign

This is the foundational constraint. If a developer can run `cosign sign` from their laptop and upload a signed artifact, there is no trust — the signing key (or OIDC identity) is independent of the build process.

Trusted builds enforce that **only the build platform** holds the signing authority:

```
❌ Developer laptop:   cosign sign myorg/myapp    # Not a trusted build
✅ CI build runner:    cosign sign myorg/myapp    # Trusted if runner is attested
```

This is achieved through:

1. **OIDC identity locked to the CI platform**: GitHub Actions OIDC tokens contain the repository, workflow, and ref. The token is only available inside the runner.
2. **Key-based with HSM**: The signing key never leaves a hardware module accessible only from the hardened build environment.
3. **Policy enforcement**: Admission controllers (e.g., Kyverno, OPA) reject images that lack platform-verified provenance.

Example using GitHub Actions OIDC — the token proves the workflow that ran:

```yaml
jobs:
  build:
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - run: make build
      - uses: actions/attest-build-provenance@v1
        with:
          subject-path: "dist/myapp.tar.gz"
```

The OIDC token has the claims:

```json
{
  "sub": "repo:myorg/myapp:ref:refs/heads/main",
  "job_workflow_ref": "myorg/myapp/.github/workflows/build.yml@refs/heads/main",
  "sha": "abc123..."
}
```

No developer can forge these claims — they are issued by GitHub's OIDC provider based on the actual workflow execution.

## Air-Gapped Signing

In high-security environments, the signing operation occurs on a machine that is never connected to a network. This prevents remote compromise from reaching the signing key.

Air-gapped signing workflow:

```
Developer → Build Platform → Artifact + Digest
                                    ↓
                            Air-Gapped Signing Station
                                    ↓
                            Signed Artifact → Registry
```

Implementation with cosign and a hardware key:

```bash
# On the air-gapped signing station:
# 1. Import the artifact digest (via USB, QR code, optical media)
# 2. Sign using HSM-backed key
cosign sign-blob --key hsm://partition/mykey \
  --output-signature artifact.sig \
  artifact.bin

# 3. Output the signature file (carried back via the same air-gap)
```

Verifiers check the signature against the known public key, which is distributed through an out-of-band trust anchor (e.g., DNS, TUF).

## HSM/TEE-Backed Keys

Hardware Security Modules (HSMs) and Trusted Execution Environments (TEEs) ensure the signing key never exists in software-accessible memory.

### HSM (e.g., YubiHSM, AWS CloudHSM, Azure Key Vault)

```bash
# PKCS#11 URI for HSM key
cosign sign --key pkcs11:object=mykey?module-path=/usr/lib/libykcs11.so \
  myorg/myapp:latest

# AWS KMS
cosign sign --key awskms:///arn:aws:kms:us-east-1:.../key/abc \
  myorg/myapp:latest

# Azure Key Vault
cosign sign --key azurekms://myvault.vault.azure.net/keys/mykey \
  myorg/myapp:latest
```

### TEE (e.g., Intel SGX, AMD SEV)

TEEs provide code isolation and remote attestation. The signing key is generated inside the enclave and never leaves. Verifiers get a signed attestation that the signing occurred inside a known enclave measurement.

```python
# Pseudocode for TEE-based signing
enclave = create_enclave(measurement_hash="abc123")
enclave.load_key()  # Key generated inside enclave, never exposed
signature = enclave.sign(artifact_digest)
quote = enclave.get_quote(signature)  # Hardware-signed proof of enclave identity
```

Verification checks both the signature and the enclave quote:

```bash
cosign verify --policy trusted-build-policy.yaml myorg/myapp:latest
```

Where the policy requires `enclave.measurement == "abc123"`.

## Threshold Signing

Threshold signing (e.g., using the `threshold` scheme in cosign) requires M-of-N signatures before an artifact is considered signed. This prevents a single compromised key from producing a valid signature.

```bash
# Each build platform holds one key share
# Verification requires M-of-N signatures

# Sign with key share
cosign sign --key cosign-shard-1.key myorg/myapp:latest

# Verify requires threshold
cosign verify --threshold 2 \
  --key public-key.pem \
  myorg/myapp:latest
```

In SLSA L4 contexts, threshold signing enforces the "no single compromised party" requirement in the cryptographic layer.

## SLSA Build Platform Requirements

SLSA defines specific requirements for the build platform itself:

| Requirement | SLSA L3 | SLSA L4 |
|---|---|---|
| Isolated build environment | ✅ | ✅ |
| Ephemeral (no state between builds) | Optional | ✅ |
| Build steps recorded in provenance | ✅ | ✅ |
| Builder ID in provenance | ✅ | ✅ |
| Build platform runs on trusted hardware | Optional | ✅ |
| Dependencies fetched before build | ✅ | ✅ (hermetic) |
| Network access during build | Allowed | Denied (hermetic) |

A trusted build platform at L4 meets all of these. Google Cloud Build and GitHub Actions hosted runners meet L3. L4 requires additional hardening — typically custom infrastructure with TEE or HSM integration.

## Policy Example

Using Kyverno to enforce that only images with valid, trusted build provenance can be deployed:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-slsa-provenance
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-provenance
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "*"
          attestors:
            - count: 1
              entries:
                - keyless:
                    subject: "*.github.com/myorg/myapp*"
                    issuer: "https://token.actions.githubusercontent.com"
          attestations:
            - predicateType: "https://slsa.dev/provenance/v1"
```

This policy rejects any Pod that references an image without a valid SLSA provenance attestation signed by the expected CI identity.

## Common Interview Questions

- "How does a build platform prove it ran the build?" — OIDC tokens (the CI provider vouches for the execution context) or TEE remote attestation (hardware vouches for code integrity)
- "What happens if the HSM fails during signing?" — Fail closed: do not deploy unsigned artifacts. Redundant HSM with threshold signing provides availability
- "Can you have trusted builds without hardware?" — Yes, using OIDC-based keyless signing (Sigstore). But hardware (HSM/TEE) provides stronger guarantees that a cloud provider compromise cannot forge signatures
- "What is the weakest link in a trusted build?" — The build dependency chain. If a build tool or base image is compromised, the build platform signs malicious output. This is why SLSA L4 requires hermetic builds and no untrusted inputs
