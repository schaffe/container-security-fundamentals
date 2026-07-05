---
title: "PR Review: Dockerfile Security Review"
section: "Docker"
order: 37
---

# PR Review: Dockerfile Security Review

## The Senior Engineer Frame

Most candidates can spot individual issues. Senior engineers ~**thematize**. The interviewer isn't testing whether you know `ADD` vs `COPY` — they're testing whether you see the pattern connecting 10 different findings into 3-4 root causes.

### The Four Axes of Dockerfile Review

Every PR review finding maps to one or more of four orthogonal axes. Together they cover the full supply chain threat model: tampering, escape, disclosure, and blind trust. A finding that spans multiple axes is usually higher severity.

---

#### Axis 1: Integrity & Reproducibility

**Threat model:** An attacker modifies the artifact or its dependencies during build, transit, or storage. The build is not reproducible, so tampering is undetectable.

**Core question:** Can this build be reliably reproduced, and if tampered, would we know?

**What's in scope:**
- `FROM` tags vs digests (floating tags mask tampering — the tag may resolve to a compromised image tomorrow)
- Lockfile enforcement (`npm ci` vs `npm install`, `pip --require-hashes`, `go.sum` verification)
- Dependency integrity (checksum verification, dependency confusion, typosquatting)
- Image signing (cosign, Docker Content Trust, Notary)
- Admission control (Kyverno `verifyImages`, OPA Gatekeeper)
- SLSA provenance attestation (build platform identity, hermetic builds)

**Why it matters for a Senior Engineer:**

This axis is where most supply chain attacks land. A compromised base image (e.g., `node:20` retagged to point at a malicious layer) propagates to every downstream consumer who blindly pulls `node:20`. Without lockfile enforcement, a PyPI account takeover silently injects malicious code into your production image. Without admission control, signing is theatre — the image is signed but nobody checks the signature.

Reproducibility is the foundation. If a build isn't reproducible, you can't verify provenance — you can't prove the image was built from the claimed source by the claimed platform. This is why SLSA L3 requires hermetic builds (no network access during build, all inputs declared), and L4 requires reproducibility (two identical builds produce byte-identical output).

**Attack scenarios:**

| Attack | Axis mapping | Defense |
|--------|-------------|---------|
| Base image tag repointed to compromised image | Integrity | Digest pinning |
| PyPI account takeover via typosquatted dependency | Integrity | Hash pinning (`--require-hashes`) |
| Registry compromise — attacker replaces pushed image | Integrity | Cosign signing + verification |
| Malicious insider pushes unsigned image | Integrity + Transparency | Kyverno admission enforce |
| CI pipeline compromised — builds use attacker-controlled cache | Integrity | BuildKit cache isolation, provenance |
| Dependency confusion (public package with same name as private) | Integrity | Package source pinning, `--extra-index-url` ordering |

**Defense layers (in increasing order of rigor):**
1. Pin by digest (`FROM node@sha256:...`) — prevents tag retagging attacks
2. Enforce lockfiles (`npm ci`, `pip freeze --require-hashes`) — prevents unexpected dependency resolution
3. Hash-verify all downloaded artifacts (`sha256sum -c`) — catches MITM during build
4. Sign the image with identity-bound key (cosign keyless) — links image to CI identity
5. Attest with provenance (SLSA provenance predicate) — proves who built what from what
6. Enforce at admission (Kyverno verifyImages) — closes the verification loop

**Interview depth:**

Be ready to discuss why SLSA L4 requires reproducibility. The answer is about **verification without trust**: if two independent build platforms produce identical outputs, you don't need to trust either platform. Also be ready to discuss the trade-off between digest pinning (security) and automated updates (maintainability) — the answer is Renovate/Dependabot configured to PR digest bumps with scan results.

---

#### Axis 2: Least Privilege

**Threat model:** An attacker who achieves code execution in the container can escalate privileges, escape to the host, or move laterally — because the container was granted more capability than needed.

**Core question:** Does the container have only what it needs to function?

**What's in scope:**
- Running as root (UID 0) — the single highest-severity finding on this axis
- Linux capabilities (`cap_drop: ALL` + selective add vs selective drop)
- Seccomp profiles (`RuntimeDefault` vs `Unconfined`)
- Read-only root filesystem (`readOnlyRootFilesystem: true`)
- Unnecessary packages (compilers, shells, package managers in production)
- Exposed ports that don't correspond to listening sockets
- `allowPrivilegeEscalation` — must be `false` when not needed
- `no-new-privileges` — prevents privilege escalation via setuid binaries
- AppArmor/SELinux profiles

**Why it matters for a Senior Engineer:**

Least privilege is the oldest security principle and the most consistently violated in containers. The Docker default is "root, all capabilities, writable, no seccomp" — the exact opposite. Senior engineers understand that **these controls are multiplicative, not additive**. A root container with all capabilities and no seccomp is trivially exploitable. A non-root container with only `NET_BIND_SERVICE` and `RuntimeDefault` seccomp requires chaining multiple kernel exploits for the same outcome.

The key insight is **defense in depth across OS layers**:

```
┌─────────────────────────────────────────┐
│  USER non-root          │  ── escapes    │
│  cap_drop: ALL          │  ── privilege  │
│  seccomp: RuntimeDefault│  ── syscall    │
│  readOnlyRootFilesystem │  ── writes     │
│  no-new-privileges      │  ── escalation │
└─────────────────────────────────────────┘
```

Each layer closes an escape path. An attacker who gets RCE in a non-root container must first find a kernel exploit (rare), then a way to call the required syscall (seccomp blocks most), while having no capability to mount filesystems or load kernel modules (capabilities dropped). Individually each control is bypassable. Together they're exponentially harder.

**Attack scenarios:**

| Attack | Axis mapping | Defense |
|--------|-------------|---------|
| RCE in container → write cryptominer to /tmp | Least Privilege | Read-only rootfs |
| RCE → exploit kernel via userfaultfd syscall | Least Privilege | Seccomp RuntimeDefault blocks userfaultfd |
| RCE → setuid binary for privilege escalation | Least Privilege | no-new-privileges, drop ALL capabilities |
| RCE → write to host via mount propagation | Least Privilege | Read-only rootfs + no privileged containers |
| RCE → compile exploit using gcc from image | Least Privilege | Distroless multi-stage |
| Container escape via CVE-2019-5736 (runC) | Least Privilege | Non-root user (attacker exits container's UID namespace) |

**Compounding effect — the interview answer:**

If an interviewer asks "what's the most impactful thing," the answer is **non-root execution**. Not because it's the strongest control (it isn't — seccomp blocks more attack surface), but because it unlocks everything else. Without non-root, capabilities are less meaningful (root can re-enable them), seccomp is a hedge, and read-only rootfs is partially bypassable. Non-root is the prerequisite for the entire least-privilege stack.

**Assessing blast radius of excess:**

When reviewing a Dockerfile, ask: **"If an attacker gets arbitrary code execution in this container, what can they do, and what can't they do?"**

- Root user → attacker owns the container namespace, can unmount protections, re-enable capabilities
- Capabilities like `SYS_ADMIN` → attacker can mount filesystems, load kernel modules, access `/dev/mem`
- `NET_ADMIN` → attacker can iptables-intercept traffic from other containers on the same host
- `SYS_PTRACE` → attacker can ptrace other processes in the same container (side-channel, credential extraction)
- Shell present → attacker can download additional tooling, chain exploits interactively
- Compiler present → attacker can compile exploits in-container (no outbound needed)

---

#### Axis 3: Confidentiality

**Threat model:** Secrets, credentials, or sensitive data embedded in the Docker build process leak to unauthorized parties — because image layers are persistent, portable, and visible to anyone with pull access.

**Core question:** Are secrets exposed anywhere in the image layers or build context?

**What's in scope:**
- `ENV` with secrets — visible in `docker history`, `docker inspect`, and every layer
- `ARG` with secrets — visible in `docker history` (both `--build-arg` value and intermediate layers)
- `COPY` of secret files without cleanup — `.env`, `credentials.json`, `service-account.json` in image
- Missing `.dockerignore` — `.git/` with credential history, local `.env`, IDE secrets
- Intermediate layers from `COPY` + `RUN chown` — file content persists in root-owned layer
- Build context leaks — files in the build directory that shouldn't be there
- CI/CD environment — ARG values logged in CI output, exposed in build metadata

**Why it matters for a Senior Engineer:**

Secrets in images are **irreversible and viral**. Once a secret enters an image layer:
1. It's in every layer (not just the final layer — `docker history` shows every instruction's result)
2. It propagates to every registry the image is pushed to (Docker Hub, ECR, GCR, private registries)
3. It's cached on every machine that pulls the image (developer laptops, CI runners, production nodes)
4. It persists in image history forever — rotating the secret doesn't remove it from already-pushed layers

The only fix for a committed secret is: (a) rotate the secret immediately, (b) delete all image tags that contain it from all registries, (c) force-repull on all nodes, (d) audit who pulled the image between commit and fix.

This makes the `ENV API_KEY` pattern the most expensive mistake a team can make. The cost isn't the secret itself — it's the incident response effort to contain the disclosure.

**Attack scenarios:**

| Attack | Axis mapping | Defense |
|--------|-------------|---------|
| CI output leaks `--build-arg NPM_TOKEN=xxx` | Confidentiality | BuildKit `--secret` |
| Image pulled from public registry, `docker history` shows DB password | Confidentiality | Never `ENV` secrets |
| Developer copies `.env` into image via `COPY . .` | Confidentiality | `.dockerignore` |
| Config file exists in root-owned intermediate layer after `RUN chown` | Confidentiality | `COPY --chown` |
| `.git/` copied into context — commit history with credentials | Confidentiality | `.dockerignore` with `.git/` |
| Scanner tool reads image history, reports secret in findings | Confidentiality | All of the above |

**Defense layers:**
1. **Never use `ENV` for secrets** — `ENV` is for configuration, not credentials. Use runtime injection (K8s Secrets, Docker secrets, vault sidecar).
2. **Never use `ARG` for secrets** — `ARG` values are visible in `docker history`. Use `--mount=type=secret` (BuildKit).
3. **Always have a `.dockerignore`** — at minimum `.git/`, `.env*`, `node_modules/`, `*.log`.
4. **Use `COPY --chown`** to avoid creating root-owned intermediate layers with sensitive content.
5. **Multi-stage builds** to strip intermediate layers — copy only what's needed to the final stage.
6. **`docker history` audit** — run `docker history <image>` in CI and fail if it contains known patterns (`ENV API`, `ENV TOKEN`, `ENV SECRET`, `ARG *_TOKEN`).

**Incident response — the interview question:**

An interviewer may ask: "A developer committed `ENV DB_PASSWORD=supersecret` and pushed to your private registry. Two hours later you discover it. What do you do?"

**Senior answer:**
> "Immediately rotate the database password. Then audit: who pulled that image tag in the last two hours? Delete all image tags that contain that layer from the registry. Force-repull on all nodes. Add a `docker history` CI check that rejects images with known secret patterns. Finally, rotate any other secrets that share the same exposure window — if someone had pull access in those two hours, assume all secrets in that image are compromised. The process fix is BuildKit secrets + `.dockerignore` + automated history scanning."

---

#### Axis 4: Transparency

**Threat model:** Consumers of the image — whether they're security scanners, deploy pipelines, or compliance auditors — cannot verify what's in the image, where it came from, or how it was built. They must trust the distributor blindly.

**Core question:** Can consumers independently verify the contents and provenance of this image?

**What's in scope:**
- SBOM generation and attestation (CycloneDX/SPDX, signed as OCI attestation)
- OCI label annotations (`org.opencontainers.image.*`)
- Signed provenance metadata (SLSA provenance predicate type)
- Vulnerability disclosure and VEX documents
- Admission control that verifies attestations (not just signatures)
- Build platform identity in attestations

**Why it matters for a Senior Engineer:**

Transparency is what separates **trust from verification**. Without transparency, consumers must trust the image distributor. With transparency, consumers can independently verify. This is the difference between "Docker says this image is safe" and "I can verify this image was built from commit abc123 on a SLSA L3 platform, I can inspect every package in it, and I can confirm no new CVEs were introduced since the last scan."

Transparency also enables **automated policy**. A Kyverno policy that says "reject images with known critical CVEs" requires transparency (SBOM + CVE matching) to evaluate. A policy that says "only allow images built by our CI pipeline" requires transparency (signed provenance with build platform identity). Without transparency, these policies are impossible.

**Attack scenarios:**

| Attack | Axis mapping | Defense |
|--------|-------------|---------|
| Image contains unknown malicious dependency, no one notices | Transparency | SBOM + automated CVE scanning |
| Team ships image with known critical CVE, no policy caught it | Transparency | Policy evaluation against SBOM |
| Compliance audit asks "what was in production image version X?" | Transparency | Signed attestation stored in registry |
| Attacker replaces image in registry, consumer can't detect | Transparency + Integrity | Signed attestation + verification |
| Org needs SLSA L3 attestation for FedRAMP compliance | Transparency | Provenance attestation in CI/CD |

**Defense layers:**
1. **Generate SBOM** — `docker scout sbom` creates a CycloneDX/SPDX bill of materials
2. **Attach SBOM as attestation** — `docker scout sbom --attest` signs and stores the SBOM in the registry alongside the image, not in a separate database
3. **Add OCI labels** — source repo, commit SHA, build timestamp, version, vendor
4. **Generate provenance attestation** — SLSA provenance predicate type stating build platform, builder identity, build config, materials
5. **Enforce at admission** — Kyverno/OPA evaluates attestations at deploy time

**The practical value for a Senior Supply Chain Engineer:**

> "Without transparency, your CVE scanner is guessing. It downloads the image, extracts packages, matches against a database — but it doesn't know what the *author* claims the image contains. With an attested SBOM, you can compare: did the author say this image contains log4j 2.17.0? Does the scanner agree? The difference is actionable — if there's a discrepancy, either the build was tampered or the scanner is wrong. Both are worth investigating."

Transparency also solves the **"known exploit, not affected"** problem via VEX (Vulnerability Exploitability eXchange). If a scanner reports a CVE for a dependency that's not actually used at runtime, the image maintainer publishes a VEX statement saying "not affected." Consumers see the CVE is ignored with justification. Without transparency, every consumer must independently triage every CVE.

---

#### How the Axes Interact

The four axes are orthogonal but connected. A finding often lives at the intersection:

| Finding | Primary axis | Secondary axis | Why |
|---------|-------------|----------------|-----|
| Image not signed | Integrity | Transparency | No signature means both integrity loss and no verifiability |
| `.env` copied into image | Confidentiality | — | Secret disclosure, no secondary integrity impact |
| Root user | Least Privilege | — | Excessive capability, no direct confidentiality impact |
| No SBOM | Transparency | — | Consumer can't verify, but image may be perfectly built |
| No `.dockerignore` with `.git/` | Confidentiality | Integrity | Secret leak + `.git/` in context could be modified during build |
| Kyverno enforcement | Integrity | Transparency | Closes the loop on both axes |
| `COPY` without `--chown` then `RUN chown` | Confidentiality | Least Privilege | Secret in root layer + root access needed to fix ownership |

**Severity triage across axes:**

When prioritizing findings in a PR review:

1. **P0 — Block the PR:** Secrets in `ENV` or `ARG` (Confidentiality), root user with all capabilities (Least Privilege), remote `ADD` without checksum (Integrity)
2. **P1 — Fix in this PR:** Floating tags (Integrity), no `.dockerignore` (Confidentiality), `build-essential` in prod (Least Privilege), no HEALTHCHECK (Reliability)
3. **P2 — Fix before merge, separate PR OK:** No seccomp profile (Least Privilege), no SBOM (Transparency), multi-stage optimization (Least Privilege)
4. **P3 — Follow-up item:** Missing OCI labels (Transparency), `ADD --chmod` instead of `COPY` + `RUN chmod` (Optimization), EXPOSE cleanup (Least Privilege)

The severity of a finding depends on:
- **Exploitability** — how easy is it to exploit? `ENV` with API key: attacker just runs `docker history`. Floating tag: attacker must compromise the registry.
- **Blast radius** — how much damage if exploited? Root user: container escape → host compromise. No HEALTHCHECK: best case is delayed restarts.
- **Persistence** — how hard to fix after the fact? Secret in layer: incident response, rotation, audit. No seccomp: just add the profile.
- **Detectability** — would we notice exploitation? Unsigned image replaced: probably not. Root container cryptomining: maybe via resource monitoring.

A senior PR review response groups findings by axis, orders by severity, and connects them to both the specific code and the broader engineering system. The output is not a list of complaints — it's a **security-informed refactoring recommendation** that a team lead can act on.

---

## Structuring a PR Review Response

### Level 1: "I see a problem" (Junior)

> "You should use `COPY` instead of `ADD`."

### Level 2: "I see the problem and can explain why" (Mid)

> "Use `COPY` instead of `ADD` because `ADD` auto-extracts tarballs and fetches remote URLs silently — both are surprising behaviors that break reproducibility. `ADD` from URLs lacks checksum verification and cache support."

### Level 3: "I see the pattern and can prioritize" (Senior)

> "This PR has several `ADD` usage issues. `ADD` for remote URLs is a supply chain integrity risk — no checksum verification, no cache. This connects to a broader pattern I'm seeing: **the Dockerfile doesn't pin anything**. Tags are floating, no lockfile enforcement, no digests. That's three findings across `FROM`, `ADD`, and dependency install, all from the same root cause — no commitment to reproducibility. Let me flag them together..."
>
> Then the reviewer **prioritizes**:
> - **P0**: `ADD` with remote URL — supply chain integrity, block the PR
> - **P1**: Floating `FROM` tags — high blast radius, fix in this PR
> - **P2**: No `.dockerignore` — medium, can follow up

### Level 4: "I can teach the team" (Staff+)

> Same as Level 3 + "Here's a pattern I want us to adopt across the org: a `.dockerfile-lint.yml` config that enforces pinned digests, no `ADD`, no root user. I'll add it to the CI pipeline and create a PR template with a Dockerfile checklist."

---

## 25 Dockerfile PR Review Snippets

### 1. `ADD` vs `COPY`

```dockerfile
# PR submitted:
ADD https://example.com/binary.tar.gz /tmp/
ADD package.tar.gz /app/
```

**Issues:** `ADD` auto-extracts tarballs and fetches remote URLs — both are surprising behaviors. `ADD` from URLs doesn't cache and exposes build to MITM.

**PR Response (Senior frame — Integrity axis):**
> "`ADD` with remote URLs has no checksum verification or caching — this is a supply chain integrity risk. Combined with the floating tag on line 3, the Dockerfile has **zero reproducibility guarantees**. Let's switch to `COPY` for local files and `curl` + `sha256sum` for remote downloads."

```dockerfile
# Fixed:
COPY package.tar.gz /tmp/
RUN curl -fsSLo /tmp/binary.tar.gz https://example.com/binary.tar.gz \
  && echo "<expected-sha256> /tmp/binary.tar.gz" | sha256sum -c -
```

---

### 2. Running as Root

```dockerfile
# PR submitted:
FROM node:20
WORKDIR /app
COPY . .
RUN npm install
CMD ["node", "server.js"]
```

**Issues:** Container runs as root (UID 0). Container breakout gives host root.

**PR Response (Senior frame — Least Privilege axis):**
> "This runs as root — the most common container security finding and the highest severity. If this container is compromised, the attacker has root in the container and a kernel exploit away from host root. We should adopt a **non-root by default** policy across all services. The `runAsNonRoot: true` K8s admission check will also catch this, but fixing it in the image is the right layer."

```dockerfile
# Fixed:
FROM node:20
WORKDIR /app
RUN groupadd -r appgroup -g 1001 \
  && useradd -r -g appgroup -u 1001 appuser
COPY --chown=appuser:appgroup . .
RUN npm ci --only=production
USER appuser
CMD ["node", "server.js"]
```

---

### 3. Pinning Base Image Tags

```dockerfile
# PR submitted:
FROM node:20
```

**Issues:** Floating tag. Breaks reproducibility. Base image change could introduce new CVEs or breaking changes.

**PR Response (Senior frame — Integrity axis):**
> "The floating `node:20` tag means every build could pull a different base image. This is both a security risk (silent CVE introduction) and a debugging nightmare (works-on-my-machine). Let's pin by digest. For ongoing updates, I recommend Dependabot or Renovate configured with a security-only update policy — automated PRs for digest bumps that we review."

```dockerfile
# Fixed:
FROM node:20@sha256:abc123def456...
```

---

### 4. Multi-stage Build with Distroless Final Stage

```dockerfile
# PR submitted:
FROM golang:1.22 as builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server

FROM alpine:3.20
COPY --from=builder /app/server /server
EXPOSE 8080
CMD ["/server"]
```

**Issues:** Alpine has ~30 packages including shell and apk. The binary is statically linked — doesn't need them.

**PR Response (Senior frame — Least Privilege axis):**
> "Since `CGO_ENABLED=0` produces a statically linked binary, Alpine's musl, apk, and shell are unreachable code — but they're still attack surface. This is the classic argument for distroless: the binary doesn't need a package manager or shell at runtime, so don't ship them. `gcr.io/distroless/static-debian12:nonroot` is the right base here."

```dockerfile
# Fixed:
FROM golang:1.22 as builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=builder /app/server /server
EXPOSE 8080
ENTRYPOINT ["/server"]
```

---

### 5. `apt-get` Cleanup Chains

```dockerfile
# PR submitted:
FROM ubuntu:22.04
RUN apt-get update
RUN apt-get install -y curl ca-certificates
RUN apt-get clean
```

**Issues:** Stale layer caching. Lists dir (`/var/lib/apt/lists/*`) persists across layers.

**PR Response (Senior frame — Least Privilege axis):**
> "This pattern creates three problems: (1) `apt-get update` in its own layer means stale cached package lists — subsequent builds don't refresh; (2) `/var/lib/apt/lists/*` persists in the final image (unnecessary bulk); (3) three layers where one suffices. Combine into a single `RUN` and clean up in the same step."

```dockerfile
# Fixed:
FROM ubuntu:22.04
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && apt-get clean
```

---

### 6. `COPY --chown` Instead of `RUN chown`

```dockerfile
# PR submitted:
COPY config.yaml /app/config.yaml
RUN chown appuser:appgroup /app/config.yaml
```

**Issues:** Sensitive file content exists in a root-owned intermediate layer. Extra layer.

**PR Response (Senior frame — Confidentiality axis):**
> "The `COPY` creates a root-owned layer with the file content, then `chown` creates another. The root-owned layer is permanent in the image — anyone with pull access can extract the file's contents from that layer. `COPY --chown` solves both the layer count and the confidentiality issue in one instruction."

```dockerfile
# Fixed:
COPY --chown=appuser:appgroup config.yaml /app/config.yaml
```

---

### 7. Seccomp Profile Missing (K8s manifest)

```yaml
# PR submitted:
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: my-app:latest
```

**Issues:** No seccomp profile. Default is `Unconfined` on older Kubernetes.

**PR Response (Senior frame — Least Privilege axis):**
> "No seccomp profile means ~450 syscalls are available when ~300 are unnecessary. This is part of a broader pattern: the container has no `securityContext` at all. Let's add `RuntimeDefault` seccomp, drop all capabilities, set `runAsNonRoot`, and `readOnlyRootFilesystem` as a batch. These are all the same principle — **least privilege at every OS layer**."

```yaml
# Fixed:
spec:
  securityContext:
    seccompProfile:
      type: RuntimeDefault
  containers:
  - name: app
    image: my-app:latest
    securityContext:
      allowPrivilegeEscalation: false
      capabilities:
        drop: ["ALL"]
      runAsNonRoot: true
```

---

### 8. Dropping All Capabilities (K8s manifest)

```yaml
# PR submitted:
    securityContext:
      capabilities:
        drop: ["NET_RAW"]
```

**Issues:** Only one capability dropped. 40+ remain.

**PR Response (Senior frame — Least Privilege axis):**
> "Dropping only `NET_RAW` is like locking one door and leaving 40 others open. The `DROP ALL, ADD BACK` pattern is a security fundamental for containers. Most apps need `NET_BIND_SERVICE` at most. This also connects to the seccomp profile — they're complementary: capabilities gate what you can request, seccomp gates what the kernel actually executes."

```yaml
# Fixed:
    securityContext:
      capabilities:
        drop: ["ALL"]
        add: ["NET_BIND_SERVICE"]
```

---

### 9. Read-only Root Filesystem (K8s manifest)

```yaml
# PR submitted:
# No readOnlyRootFilesystem
```

**Issues:** Writable rootfs by default.

**PR Response (Senior frame — Least Privilege axis):**
> "Writable rootfs is the default and it's wrong for production. A compromised container can write to any directory. The pattern is: `readOnlyRootFilesystem: true` + explicit `emptyDir` mounts for `/tmp`, `/var/run`, `/var/log`. This makes the attack surface explicit — every write path is intentional and visible."

```yaml
# Fixed:
    securityContext:
      readOnlyRootFilesystem: true
    volumeMounts:
    - name: tmp
      mountPath: /tmp
    - name: varrun
      mountPath: /var/run
  volumes:
  - name: tmp
    emptyDir: {}
  - name: varrun
    emptyDir: {}
```

---

### 10. Cosign Image Signing in CI/CD

```yaml
# PR submitted:
- name: Build and push
  run: |
    docker build -t registry.example.com/app:${{ github.sha }} .
    docker push registry.example.com/app:${{ github.sha }}
```

**Issues:** No signing. Image authenticity unverifiable.

**PR Response (Senior frame — Integrity axis):**
> "The image is pushed unsigned. Without a signature, anyone with registry write access can replace the image and consumers can't detect it. This is the single most impactful supply chain control we can add — keyless signing with cosign is free (Fulcio certs, Rekor transparency log). I'd also add SBOM attestation so downstream consumers can verify exactly what packages are in the image."

```yaml
# Fixed:
- name: Build, sign, and push
  env:
    COSIGN_EXPERIMENTAL: "1"
  run: |
    IMAGE=registry.example.com/app:${{ github.sha }}
    docker build -t $IMAGE .
    docker push $IMAGE
    cosign sign $IMAGE
    cosign attest --predicate sbom.spdx.json --type spdx $IMAGE
    cosign attest --predicate provenance.json --type slsaprovenance $IMAGE
```

---

### 11. BuildKit Secrets for Build-Time Credentials

```dockerfile
# PR submitted:
ARG NPM_TOKEN
RUN npm config set //registry.npmjs.org/:_authToken ${NPM_TOKEN}
RUN npm install --only=production
```

**Issues:** Token leaks in image history.

**PR Response (Senior frame — Confidentiality axis):**
> "The `ARG NPM_TOKEN` value is visible in `docker history`. Any developer, CI system, or registry scanner can extract it. This is a **secret leaking into image layers** — one of the most common supply chain leaks we see. BuildKit's `--secret` flag mounts the credential ephemerally during build; it never enters the layer chain. This should be our standard pattern for private registry auth."

```dockerfile
# Fixed (Dockerfile):
RUN --mount=type=secret,id=npmrc \
  cp /run/secrets/npmrc ~/.npmrc && \
  npm install --only=production

# Build command:
# docker build --secret id=npmrc,src=.npmrc -t my-app .
```

---

### 12. SBOM Generation in CI/CD

```yaml
# PR submitted:
- name: Build image
  run: docker build -t app:latest .
```

**Issues:** No SBOM generated.

**PR Response (Senior frame — Transparency axis):**
> "No SBOM means nobody downstream can verify what's in this image. Every consumer — whether it's a security scanner, a deploy pipeline, or a compliance auditor — works in the dark. Docker Scout can generate and attach an SBOM as an OCI attestation in one step. This gives us **verifiable, signed package transparency** without any external database dependency."

```yaml
# Fixed:
- name: Build and generate SBOM
  run: |
    docker build -t app:latest .
    docker scout sbom --attest app:latest
    docker push app:latest
```

---

### 13. Docker Compose Security Context

```yaml
# PR submitted:
services:
  app:
    image: my-app:latest
    ports:
      - "80:8080"
    volumes:
      - ./data:/app/data
```

**Issues:** No security constraints.

**PR Response (Senior frame — Least Privilege axis):**
> "Local Docker Compose environments should follow the same hardening patterns as production K8s. Otherwise developers get a 'works on my laptop' environment that behaves completely differently and never catches security issues. Compose supports `cap_drop`, `security_opt`, `read_only`, and `user` — we should mirror our production posture here."

```yaml
# Fixed:
services:
  app:
    image: my-app:latest
    ports:
      - "8080:8080"
    security_opt:
      - no-new-privileges:true
      - seccomp=seccomp-profile.json
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    user: "1001:1001"
    read_only: true
    tmpfs:
      - /tmp
    volumes:
      - ./data:/app/data
```

---

### 14. Verifying Signed Images with Kyverno (K8s policy)

```yaml
# PR submitted: No admission policy
```

**Issues:** Any unsigned image can deploy.

**PR Response (Senior frame — Integrity + Transparency axes):**
> "Without admission control for image verification, **signing gives us no value**. Signing is only half the solution — the other half is enforcement at deploy time. A Kyverno `verifyImages` policy that rejects unsigned images or images signed by unknown identities closes the loop. This connects to what we discussed in the CI/CD pipeline: once images are signed, we need the cluster to enforce it."

```yaml
# Fixed (Kyverno policy):
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  rules:
  - name: verify-cosign
    match:
      any:
      - resources:
          kinds:
          - Pod
    verifyImages:
    - image: "registry.example.com/*"
      keyless:
        subject: "https://github.com/myorg/myapp/.github/workflows/build.yml@refs/heads/main"
        issuer: "https://token.actions.githubusercontent.com"
```

---

### 15. Notary / Docker Content Trust

```bash
# PR submitted:
export DOCKER_CONTENT_TRUST=0
docker push registry.example.com/app:latest
```

**Issues:** DCT disabled, no tag signing.

**PR Response (Senior frame — Integrity axis):**
> "Disabling DCT means the push skips tag signing in Notary. Consumers can't verify image origin. For production images, we should require DCT or cosign — but not both without ceremony. The key architectural choice is: **TUF (Notary) for repository integrity, Sigstore for per-artifact attestation**. They solve different problems."

```bash
# Fixed:
docker trust signer add --key ci-signer.pub production
docker trust sign ci-signer registry.example.com/app:latest
```

---

### 16. Layer Caching — Copying Dependencies Before Source

```dockerfile
# PR submitted:
FROM python:3.12-slim
WORKDIR /app
COPY . .
RUN pip install -r requirements.txt
```

**Issues:** Every source change busts the pip cache.

**PR Response (Senior frame — Build optimization + Integrity):**
> "Copying source before dependencies means every code change re-installs all dependencies. Docker caches layers by instruction — `COPY requirements.txt` before `COPY .` means `RUN pip install` only reruns when `requirements.txt` changes. This is the biggest build optimization we can make, and it also makes our CI failures more reproducible (dependency resolution is a separate cacheable step)."

```dockerfile
# Fixed:
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
```

---

### 17. `RUN npm install` Without `npm ci`

```dockerfile
# PR submitted:
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm install
COPY . .
```

**Issues:** `npm install` ignores lockfile semantics.

**PR Response (Senior frame — Integrity axis):**
> "`npm install` may regenerate `package-lock.json` or install different versions than what's locked. This is a reproducibility and supply chain integrity risk — if someone tampers with the lockfile, `npm install` silently overwrites it. We also need `--require-hashes` for dependency integrity verification."

```dockerfile
# Fixed:
FROM node:20-slim
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --only=production
COPY . .
```

---

### 18. Hardcoding Secrets in Dockerfile

```dockerfile
# PR submitted:
FROM python:3.12-slim
ENV API_KEY="sk-abc123def456"
ENV DB_PASSWORD="supersecret"
COPY . .
CMD ["python", "app.py"]
```

**Issues:** Secrets baked into image. Anyone with pull access can extract via `docker history`.

**PR Response (Senior frame — Confidentiality axis):**
> "`ENV` with secrets is the most critical confidentiality finding. Every single person with image pull access — every developer, every CI system, every registry scanner — can extract these secrets from `docker history`. The secret is also in every registry replica, every cached layer, every developer's local store. **Secrets in ENV propagate irreversibly.** This blocks the PR."

```dockerfile
# Fixed — no ENV secrets.
# Secrets injected at runtime via K8s Secrets / Docker secrets.
```

---

### 19. `COPY . /app` Without `.dockerignore`

```dockerfile
# PR submitted:
FROM golang:1.22
WORKDIR /app
COPY . .
RUN go build -o /app/server
```

**Issues:** `.git/`, `.env`, `node_modules/`, IDE configs all copied into context.

**PR Response (Senior frame — Confidentiality + Build optimization):**
> "Without `.dockerignore`, we're copying the entire repository including `.git/` (commit history), any `.env` files (potential secrets), and local build artifacts. This is both a confidentiality risk and a build performance issue. A `.dockerignore` is a security-critical file — it should be checked into the repo and reviewed like any other config."

```
# .dockerignore:
.git/
node_modules/
.env*
*.md
.gitignore
.dockerignore
.DS_Store
.docker/
*.log
```

---

### 20. `EXPOSE` Without Port Justification

```dockerfile
# PR submitted:
EXPOSE 3000
EXPOSE 8080
EXPOSE 5432
CMD ["node", "server.js"]
```

**Issues:** Three exposed ports, including a database port in an app image.

**PR Response (Senior frame — Least Privilege axis):**
> "`EXPOSE 5432` suggests a database bundled in the application image — which is a single-responsibility violation. Even if Postgres isn't running, the exposed port creates unnecessary network attack surface within the cluster. An attacker who compromises this container can reach port 5432. Every `EXPOSE` should correspond to a port the application socket actually listens on."

```dockerfile
# Fixed:
EXPOSE 8080
CMD ["node", "server.js"]
```

---

### 21. Installing `build-essential` in Production Image

```dockerfile
# PR submitted:
FROM python:3.12-slim
RUN apt-get update && apt-get install -y build-essential libssl-dev
COPY requirements.txt .
RUN pip install -r requirements.txt
COPY . .
CMD ["python", "app.py"]
```

**Issues:** Compilers (~200 MB) in production image. Attack surface for cryptominer installation.

**PR Response (Senior frame — Least Privilege axis):**
> "`build-essential` ships compilers, linkers, and headers — none of which are needed at runtime. If an attacker gains code execution in this container, they have `gcc` available without downloading anything. This is a canonical multi-stage build argument: compile in a builder stage with build tools, ship only the compiled artifacts in runtime."

```dockerfile
# Fixed:
FROM python:3.12-slim AS builder
RUN apt-get update && apt-get install -y build-essential libssl-dev
WORKDIR /app
COPY requirements.txt .
RUN pip install --user -r requirements.txt

FROM python:3.12-slim
COPY --from=builder /root/.local /root/.local
COPY . .
ENV PATH=/root/.local/bin:$PATH
CMD ["python", "app.py"]
```

---

### 22. `RUN pip install` Without Hash Checking

```dockerfile
# PR submitted:
FROM python:3.12-slim
COPY requirements.txt .
RUN pip install -r requirements.txt
```

**Issues:** No checksum verification. Dependency confusion / typosquatting not detected.

**PR Response (Senior frame — Integrity axis):**
> "Without `--require-hashes`, pip resolves dependencies dynamically and trusts PyPI's response. A compromised dependency (dependency confusion, account takeover, typosquatting) installs without warning. Generate `requirements.txt` with `--generate-hashes` and enforce with `--require-hashes`. This gives us **reproducible, tamper-evident dependency resolution**."

```dockerfile
# Fixed:
FROM python:3.12-slim
COPY requirements.txt .
RUN pip install --require-hashes -r requirements.txt
```

---

### 23. `ADD --chmod` for Executable Bits

```dockerfile
# PR submitted:
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
```

**Issues:** Extra layer for permission change.

**PR Response (Senior frame — Layer optimization):**
> "Two layers where one suffices. `ADD --chmod` (or `COPY --chmod` with BuildKit) sets permissions at copy time. This is a small optimization for a single entrypoint, but across 50 services, eliminating unnecessary layers reduces pull times and storage."

```dockerfile
# Fixed:
ADD --chmod=0755 entrypoint.sh /entrypoint.sh
```

---

### 24. `CMD` vs `ENTRYPOINT` Confusion

```dockerfile
# PR submitted:
FROM alpine:3.20
ENTRYPOINT ["/bin/server"]
CMD --config /etc/config.yaml
# But also:
CMD /bin/server --config /etc/config.yaml
```

**Issues:** Two CMDs (last wins). Shell form wraps in `/bin/sh -c` — signal handling broken.

**PR Response (Senior frame — Reliability):**
> "The shell form wraps the command in `/bin/sh -c`, making the shell PID 1. `SIGTERM` goes to the shell, which may not forward it to the actual server process. This causes delayed shutdowns and potential data loss in production. Use exec form everywhere. The `ENTRYPOINT`/`CMD` split is intentional: `ENTRYPOINT` is the binary, `CMD` is the default arguments — it's clean when used correctly."

```dockerfile
# Fixed:
ENTRYPOINT ["/bin/server"]
CMD ["--config", "/etc/config.yaml"]
```

---

### 25. `HEALTHCHECK` Missing

```dockerfile
# PR submitted:
FROM nginx:1.25
COPY custom.conf /etc/nginx/conf.d/
```

**Issues:** No HEALTHCHECK. Container runtime can't detect deadlocked process.

**PR Response (Senior frame — Reliability):**
> "Without `HEALTHCHECK`, the orchestrator only knows if the process is running (PID exists), not if it's *working*. A deadlocked or hung process keeps running but serves no requests. This is especially important for nginx and other reverse proxies where the process often survives config errors. The health check should test actual functionality (`curl /healthz`), not process existence."

```dockerfile
# Fixed:
FROM nginx:1.25
COPY custom.conf /etc/nginx/conf.d/
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD curl --fail http://localhost:80/healthz || exit 1
```

---

### Bonus: `LABEL` for Supply Chain Metadata

```dockerfile
# PR submitted:
FROM alpine:3.20
COPY app /app
CMD ["/app"]
```

**Issues:** No provenance metadata.

**PR Response (Senior frame — Transparency axis):**
> "This image ships with zero metadata. Downstream consumers — security scanners, audit tools, compliance systems — can't answer basic questions: who built this? from what source? what version? OCI standard labels give us that. Combined with signed attestations (cosign + SBOM), this creates a **verifiable chain from source commit to running container**."

```dockerfile
# Fixed:
FROM alpine:3.20
LABEL org.opencontainers.image.source="https://github.com/myorg/myapp"
LABEL org.opencontainers.image.version="1.2.3"
LABEL org.opencontainers.image.revision="abc123def456"
LABEL org.opencontainers.image.created="2026-06-09T10:00:00Z"
LABEL org.opencontainers.image.title="my-app"
LABEL org.opencontainers.image.vendor="MyOrg"
COPY app /app
CMD ["/app"]
```

---

## Interview Questions to Expect

### "How do you structure a PR review for a Dockerfile?"

**Senior answer:**
> "I scan along **four axes**: Integrity, Least Privilege, Confidentiality, Transparency. Most findings map to one of these. I group related findings — if I see no digest pinning, no lockfile enforcement, and `npm install` without `npm ci`, that's one root cause (no reproducibility commitment), not three separate issues. I prioritize: secrets leaking are an automatic block, everything else I calibrate to blast radius and exploitability."
>
> "Then I look at whether the PR has a **hardening baseline**. If there's no `.dockerignore`, no `USER`, no `--chown`, and `build-essential` in prod — that's a team-wide pattern problem. I'd block the PR and suggest we add a Dockerfile linter (Hadolint) and a PR template checklist."

### "What's the single most impactful thing a team can do for Docker security?"

**Senior answer:**
> "Non-root execution. It's the cheapest, highest-ROI control. Every other hardening measure — capabilities, seccomp, read-only rootfs — builds on it. If the container runs as root, a lot of the other controls are hedge bets rather than guarantees. I'd rather a team does **non-root + digest pinning + signing** before they optimize seccomp profiles or multi-stage builds."

### "How do you balance developer velocity with container security?"

**Senior answer:**
> "The key is **shift-left without friction**. We shouldn't make developers memorize 25 rules. Instead:"
> 1. "Hadolint in CI — fails on P0 issues (secrets, root user, no digest)"
> 2. "PR template with a Dockerfile checklist — 3-4 checks, not 25"
> 3. "Central base images with hardening baked in — teams consume distroless with non-root and seccomp without thinking about it"
> 4. "Cosign + Kyverno as an automated gating layer — if the image isn't signed, the admission controller rejects it"
>
> "The goal is to make the **secure path the easiest path**. If the hardened base image is the default, security happens by accident."

### "You mentioned confidentiality vs integrity — elaborate."

**Senior answer:**
> "They're often confused. **Confidentiality** is about secrets leaking — ENV with API keys, ARG values in history, `.dockerignore` gaps. The threat model is information disclosure. **Integrity** is about tampering — unsigned images, floating tags, no hash verification. The threat model is an attacker modifying the artifact. They require different controls: BuildKit secrets for confidentiality, cosign + DCT for integrity. A privacy breach (leaked DB password) and a supply chain attack (tampered image) are different incidents with different responses."

---

## Quick Reference: 25 Findings by Axis

| Axis | Finding Numbers |
|------|----------------|
| **Integrity & Reproducibility** | 1 (ADD), 3 (digests), 10 (signing), 11 (secrets), 14 (kyverno), 15 (DCT), 17 (npm ci), 22 (pip hashes) |
| **Least Privilege** | 2 (root user), 4 (distroless), 5 (apt cleanup), 7 (seccomp), 8 (capabilities), 9 (readonly), 13 (compose), 20 (EXPOSE), 21 (build-essential) |
| **Confidentiality** | 6 (COPY --chown), 11 (BuildKit secrets), 18 (ENV secrets), 19 (.dockerignore) |
| **Transparency** | 12 (SBOM), 14 (kyverno enforcement), bonus (LABEL) |
| **Reliability** | 24 (CMD/ENTRYPOINT), 25 (HEALTHCHECK) |
| **Build Optimization** | 16 (layer order), 23 (ADD --chmod) |
