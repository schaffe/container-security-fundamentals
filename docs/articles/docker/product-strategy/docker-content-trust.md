---
title: "Docker Content Trust and Notary v2"
section: "Docker Product & Strategy"
order: 27
---

# Docker Content Trust and Notary v2

## Overview

Docker Content Trust (DCT) is Docker's implementation of cryptographic image signing and verification. It ensures that the images you pull are exactly what the publisher pushed — unmodified, properly signed, and traceable to a specific signing identity. DCT is built on The Update Framework (TUF) and was historically backed by Notary v1. The ecosystem is transitioning to Notary v2 (also called Notation), which aligns with broader industry standards.

Understanding DCT is critical for a supply chain security role because it addresses the fundamental question: *"Can I trust that this image came from who I think it did, and that it hasn't been tampered with?"*

---

## The Update Framework (TUF)

DCT is rooted in TUF, a framework designed to secure software update systems. TUF solves several key problems that naive signature schemes don't address:

| Problem | TUF Solution |
|---------|-------------|
| Key compromise | Hierarchical key hierarchy; compromise of online keys doesn't compromise root of trust |
| Rollback attacks | Signed, monotonically increasing version numbers |
| Indefinite freeze attacks | Timestamp role provides freshness guarantees |
| Endless data attacks | Snapshot role pins the set of metadata files |
| Mix-and-match attacks | Metadata is cryptographically linked; partial metadata is rejected |

TUF's design means that even if an attacker compromises the server distributing images, they cannot produce valid metadata for an older, vulnerable version of an image (rollback) or selectively withhold update metadata (mix-and-match).

---

## Key Hierarchy

DCT and Notary use a five-key hierarchy based on TUF roles:

```
Root Key (offline, highly protected)
 ├── Targets Key (online, signs image metadata)
 ├── Snapshot Key (online, signs the snapshot of all metadata)
 └── Timestamp Key (online, frequent rotation, signs freshness)
     └── Delegation Keys (optional, per-team or per-repo)
```

### Root Key

- **Storage**: Offline, typically on a hardware security module (HSM), YubiKey, or air-gapped storage
- **Usage**: Signs the root metadata file, which establishes the trust root for a repository
- **Rotation**: Rare; requires re-signing all downstream metadata
- **Security posture**: Must never exist on a network-connected machine

### Targets Key

- **Storage**: Online (server-side), but should be protected with access controls
- **Usage**: Signs the targets metadata, which lists the digests of all signed images in a repository
- **Rotation**: More frequent than root; does not invalidate root trust

### Snapshot and Timestamp Keys

- **Snapshot**: Signs the metadata that lists the current versions of all other metadata files
- **Timestamp**: Signed frequently (minutes to hours) to provide freshness guarantees; clients can detect if the repository stops publishing updates
- **Storage**: Online, server-side
- **Rotation**: Timestamp keys can be rotated automatically

### Delegation Roles

Delegations allow the repository owner to delegate signing authority to specific teams or CI/CD pipelines:

```bash
# Create a delegation for the security team
notary delegation add \
  my-registry.wild.mycompany.com/my-app \
  targets/security-team \
  --paths "security-team/*" \
  --signing-keys security-team-key.pub

# The security team can now sign images under the delegated path
docker trust sign --local security-team/my-scanner:latest
```

This enables granular access control: the platform team manages the root and targets keys, while individual product teams hold their own delegation keys and sign their own images.

---

## Docker Content Trust in Practice

### Enabling DCT

```bash
# Enable DCT for all docker push/pull operations
export DOCKER_CONTENT_TRUST=1

# Or enable per-command
docker pull --disable-content-trust=false alpine:latest

# Check trust data for an image
docker trust inspect alpine:latest
```

### Signing an Image

```bash
# Generate signing keys
docker trust key generate my-signing-key

# Sign an image (push with trust)
docker trust sign my-app:latest

# Inspect trust data
docker trust inspect --pretty my-app:latest

# List delegation keys
docker trust signer list my-app:latest
```

### Verification on Pull

When DCT is enabled, `docker pull` verifies:

1. **Integrity**: The image digest matches the signed digest in targets metadata
2. **Freshness**: The timestamp metadata is recent (within configured threshold)
3. **Trust chain**: The targets metadata is signed by a key that chains to the root
4. **No rollback**: The version numbers are strictly increasing

If verification fails, the pull is rejected:

```bash
$ docker pull my-registry/my-app:latest
Error: remote trust data does not exist for my-registry/my-app:latest: 
notary.tuf: data does not exist
```

---

## Notary v1 Limitations

DCT was originally built on Notary v1, which had several practical limitations:

1. **Complex key management**: The five-key TUF hierarchy is powerful but operationally complex. Organizations struggled with safe root key storage and rotation procedures.

2. **Server dependency**: Notary requires a running notary server alongside the registry. Many Docker Registry deployments (especially registries other than Docker Hub) don't include a notary server.

3. **No standard delegation model**: While TUF supports delegations, Notary v1's implementation was tightly coupled to the notary server and didn't align with OCI distribution spec.

4. **No OCI artifact support**: Notary v1 was designed before the OCI Artifact Distribution specification. It couldn't sign artifacts other than container images.

5. **Single signer per image**: The delegation model allowed multiple signers, but the workflow was cumbersome and not widely adopted.

6. **Poor integration with CI/CD**: Automating signing in CI/CD pipelines required storing signing keys in CI secrets, which is operationally risky.

---

## Notary v2 / Notation

Notary v2, now called Notation (Notary v2), addresses Notary v1's limitations by aligning with OCI standards and modern signing practices:

### Key Improvements

1. **OCI-compliant**: Signatures are stored as OCI artifacts in the same registry, alongside the image. No separate notary server is needed.

2. **Simplified key model**: Notation uses a simpler key hierarchy:
   - **Signing key**: The key used to sign artifacts
   - **Trust store**: Collection of trusted X.509 certificates (roots and intermediates)
   - **Trust policy**: JSON/YAML configuration that defines verification rules

3. **X.509 certificate-based**: Notation uses X.509 certificates rather than TUF's custom key format. This allows integration with existing PKI infrastructure (internal CAs, public CAs, KMS).

4. **Plugin architecture**: Notation supports extensible signing and verification plugins, enabling integration with KMS providers (AWS KMS, Azure Key Vault, GCP Cloud KMS, HashiCorp Vault).

### Notation Signing Workflow

```bash
# Generate a signing key (or use existing PKI)
notation cert generate-test --default "my-signing-key"

# Sign an image (signature stored as OCI artifact)
notation sign my-registry/my-app:latest

# Verify an image
notation verify my-registry/my-app:latest

# List signatures for an image
notation ls my-registry/my-app:latest

# Sign with a KMS-managed key
notation sign --key "awskms:///arn:aws:kms:..." my-registry/my-app:latest
```

### Notation Trust Policy

```json
{
  "version": "1.0",
  "trustPolicies": [
    {
      "name": "my-org-policy",
      "registryScopes": ["my-registry/my-app"],
      "signatureVerification": {
        "level": "strict"
      },
      "trustStores": ["ca:my-org-ca"],
      "trustedIdentities": ["x509.subject:CN=CI-CD-Signer,O=My Org"]
    }
  ]
}
```

---

## Relationship with Sigstore

Sigstore (cosign, Fulcio, Rekor) and Notation serve similar purposes but with different philosophies:

| Aspect | Notation (Notary v2) | Sigstore (cosign) |
|--------|---------------------|-------------------|
| Identity model | X.509 certificates (existing PKI) | Ephemeral keys + OIDC identity |
| Key management | Long-lived or KMS-backed keys | Short-lived, auto-generated per sign |
| Transparency log | Optional (not required by spec) | Required (Rekor) |
| Registry requirement | OCI-compliant registry | OCI-compliant registry |
| Standardization | OCI spec, CNCF | CNCF, Linux Foundation |
| Key compromise | Revoke certificate via CRL/OCSP | Rotate identities (no key to revoke) |

Docker's strategy is to support both Notation and cosign, with Notation as the recommended path for DCT and DHI attestations. The ecosystem is converging on Notation as the OCI standard, while cosign remains popular for its ease of use, especially in CI/CD.

---

## Docker's Evolution Path

Docker has publicly committed to evolving content trust along these lines:

1. **Notation as default**: New signing workflows use Notation; Notary v1 remains supported but is not being actively developed
2. **Integration with Scout**: Signed images are verified by Scout during policy evaluation, creating a chain: sign → verify → analyze → gate
3. **OCI Artifact Signatures**: Docker Hub supports Notation signatures as OCI artifacts, making signing available without a separate notary server
4. **Key management tooling**: Docker is investing in tooling to make key management more accessible (wizards for root key generation, backup, rotation procedures)
5. **Delegation via Notation**: Using Notation's trust store / trust policy model to replicate Notary v1 delegation patterns

---

## Strategic Analysis for Interview

### Key Interview Points

- **DCT != encryption**: Content trust signs images, it doesn't encrypt them. Anyone can pull a signed image; DCT verifies who published it.
- **TUF's key hierarchy is the core design**: Understanding why offline root keys matter is the most important concept.
- **Notary v1 → Notation is an industry movement, not just Docker**: The OCI standard for signing is Notation; Docker's evolution mirrors the broader ecosystem.

### Likely Interview Questions

- "A developer says DCT is too hard and wants to disable it. How do you respond?" (DCT prevents rollback attacks, mix-and-match attacks, and ensures image integrity. Simplify by using Notation with CI-managed keys and trust policies.)
- "How do you handle root key compromise?" (Revoke root certificate, publish new root metadata signed by the previous root's revocation key or through out-of-band verification. This is why offline root key storage is critical.)
- "Why does Docker support both Notation and cosign?" (Notation is the OCI standard for signing; cosign is widely adopted for its OIDC-based ephemeral key model. Docker supports both to meet different customer preferences.)
- "How does delegation work in a team of 50 developers?" (Using Notation trust policies with a shared CA: each team member has a certificate signed by the org CA; trust policy accepts any certificate from that CA with a specific subject pattern.)

For a complete walkthrough of the build pipeline that produces the images you sign, see [How Docker Builds Images](../how-docker-builds-images.md).
