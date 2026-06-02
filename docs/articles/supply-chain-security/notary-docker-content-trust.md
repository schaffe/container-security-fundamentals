---
title: "Notary / Docker Content Trust"
section: "Supply Chain Security Theory"
order: 7
---

# Notary / Docker Content Trust

## Overview

Docker Content Trust (DCT) is Docker's integration of the TUF (The Update Framework) specification to sign and verify container images. Under the hood, DCT uses **Notary** — a TUF-compliant server and client — to manage signing keys, delegations, and metadata.

Where Sigstore focuses on **per-artifact attestation** (signing individual builds), Notary/TUF focuses on **repository integrity** (ensuring you always get the latest authorized version of an image, never a stale or tampered one).

## TUF Framework

TUF is a specification for securing software update systems. It separates trust into four key roles, each with a specific responsibility and — critically — separate signing keys.

### Key Hierarchy

```
┌─────────────────────────────────────────┐
│            Root Key (offline)           │
│  Signs: root.json, rotates all keys     │
│  Storage: HSM, paper backup, offline    │
└────────────┬────────────────────────────┘
             │
    ┌────────┴────────┐
    v                 v
┌──────────┐  ┌──────────────┐
│ Targets  │  │  Snapshot     │
│ (online) │  │  (online)     │
└──────────┘  └──────┬───────┘
                     v
             ┌──────────────┐
             │  Timestamp   │
             │  (online)    │
             └──────────────┘
```

#### Root Role

The root role is the ultimate trust anchor. It signs a `root.json` that contains the public keys for all other roles and specifies which keys are authorized to sign which metadata. Root key rotation replaces the entire trust chain.

**Root key compromise requires out-of-band rotation** — distributing a new root.json signed by a backup root key.

In Docker Content Trust:

```bash
# Root key location (local)
~/.docker/trust/private/root_keys/
# Root key on Notary server
docker trust key load root.pem
```

#### Targets Role

The targets role signs `targets.json`, which lists the **digests** and **tags** of authorized images. This is the role that says "the image tagged `latest` should have digest `sha256:abc...`".

Delegation allows subdividing target signing. For example, the `releases` team signs production tags, while `ci` signs staging tags.

```json
{
  "signed": {
    "_type": "Targets",
    "spec_version": "1.0",
    "version": 2,
    "targets": {
      "myapp:latest": {
        "hashes": { "sha256": "abc123..." },
        "length": 2048
      }
    },
    "delegations": {
      "roles": [
        {
          "name": "ci",
          "keyids": ["..."],
          "paths": ["myapp:ci-*"]
        }
      ]
    }
  }
}
```

#### Snapshot Role

The snapshot role signs `snapshot.json`, which lists the **version numbers** of all current metadata files (root.json, targets.json, and any delegated targets files). This prevents mix-and-match attacks where an attacker presents an old targets.json with a new timestamp.

#### Timestamp Role

The timestamp role signs `timestamp.json`, a frequently rotated (often every few hours) metadata file containing the hash and version of the current snapshot.json. This prevents **replay attacks** — an attacker cannot serve a very old snapshot because the timestamp rotation frequency limits the window.

The timestamp key can be held by the Notary server (it is the least sensitive — if compromised, it can be rotated without affecting the other roles).

### How Verification Works

```
Client requests "myapp:latest"
  ↓
Downloads timestamp.json (always fresh)
  ↓ Has hash of current snapshot.json
Downloads snapshot.json
  ↓ Has version + hash of current targets.json
Downloads targets.json
  ↓ Has digest of myapp:latest
Downloads the actual image manifest
  ↓
Client checks: does manifest digest match targets.json entry?
```

Every link in the chain is signed. An attacker cannot substitute a stale or different version at any step.

## Docker Content Trust Workflow

### Enabling DCT

```bash
export DOCKER_CONTENT_TRUST=1

# Now all push/pull operations check and require signatures
docker push myorg/myapp:latest   # Must be signed
docker pull myorg/myapp:latest   # Verifies signature
```

When `DOCKER_CONTENT_TRUST=1`, `docker push` automatically:

1. Generates a target hash for the image manifest
2. Signs targets metadata with the targets key
3. Updates snapshot and timestamp metadata on the Notary server
4. Pushes the image manifest and layers to the registry

### Signing with Docker CLI

```bash
# Generate keys and sign a repository
docker trust sign myorg/myapp:latest

# Sign with a specific key
docker trust sign --key mykey.pem myorg/myapp:latest

# Inspect trust data
docker trust inspect myorg/myapp:latest

# Revoke a signature
docker trust revoke myorg/myapp:latest

# Manage delegations
docker trust signer add --key ci.pem ci myorg/myapp
docker trust signer remove ci myorg/myapp
```

### Key Management

Docker Content Trust maintains two keys per user:

- **Root key** (`~/.docker/trust/private/root_keys/`) — the most sensitive, should be offline
- **Repository key** (`~/.docker/trust/private/tuf_keys/`) — used to sign specific repositories

```bash
# Back up root key
docker trust key load root.pem  # Load from backup
```

### Notary Server

The Notary server stores and serves TUF metadata. Docker Hub runs a Notary server at `notary.docker.io`. Self-hosted registries can run their own:

```bash
# Run Notary server
docker run -d -p 4443:4443 \
  -v notary-config:/etc/notary \
  notary:server \
  -config=/etc/notary/config.json
```

## Notary v2 Improvements

Notary v2 (now part of the **Notary Project** under CNCF) addresses limitations in the original Notary v1:

| Feature | Notary v1 (DCT) | Notary v2 |
|---|---|---|
| Signature format | TUF metadata only | OCI artifact + TUF metadata |
| Signatures stored | Notary server side-by-side | OCI registry (referrers API) |
| Image format | Docker V2 manifest | OCI image spec + referrers |
| Verification | Docker CLI only | Any OCI-compatible tool |
| Attestations | None | Supports arbitrary attestations |
| Performance | N+1 queries per tag | Single referrers API call |
| Delegation | Complex key management | Simpler identity-based delegation |

Notary v2 stores signatures and attestations as OCI artifacts using the **referrers API**, so they live in the same registry as the image, not in a separate Notary server. This eliminates the Notary server as a single point of failure and simplifies deployment.

## Why Docker Invests in Both Notary and Sigstore

This is a common interview question. The two projects solve complementary problems:

| Notary / TUF | Sigstore |
|---|---|
| **Repository integrity** — always get the latest authorized version | **Artifact attestation** — prove who built an artifact |
| Prevents replay, mix-and-match, freeze attacks | Prevents provenance forgery |
| Key hierarchy with delegation | Ephemeral keys with OIDC binding |
| Long-lived offline root keys | No long-lived keys at all |
| Role-based (delegations for teams) | Identity-based (OIDC email/subject) |
| Focus on **update freshness** | Focus on **build integrity** |

A complete supply chain security strategy uses both:

1. **Sigstore** to attest that an artifact was built by a specific CI pipeline from known source (SLSA provenance)
2. **Notary/TUF** to ensure consumers always pull the latest signed version, preventing rollback attacks and providing delegation for multi-team publishing

Docker's strategy: Notary secures the **registry-to-consumer** channel (you always get the right image), while Sigstore (via cosign) secures the **builder-to-registry** channel (the image was built correctly). Both are needed.

## Common Interview Questions

- "How does TUF prevent replay attacks?" — The timestamp role rotates frequently; the timestamp key signs the current snapshot hash. An attacker cannot replay old metadata because the timestamp is too old
- "What does Docker Content Trust add over plain image signing?" — Repository integrity: freshness guarantees, delegation, multi-key management. Plain signing just says "someone signed this"; DCT says "the current authorized version is this"
- "Can you use cosign and DCT together?" — Yes. Cosign attaches in-toto attestations for build provenance; DCT manages tag-to-digest mappings and freshness. They operate at different layers
- "Is Notary v2 a replacement for Sigstore?" — No. Notary v2 handles repository-level trust (freshness, delegation); Sigstore handles per-artifact attestation (provenance, scan results). They are complementary
- "What happens if the Notary server is compromised?" — Root key is offline, so attacker cannot sign new targets. They can serve stale metadata (replay), but timestamp rotation limits the window. In Notary v2, signatures are stored in the OCI registry, eliminating the Notary server as a target

For a detailed walkthrough of the image build pipeline and where signing fits into the workflow, see [How Docker Builds Images](../docker/how-docker-builds-images.md).
