---
title: "PR Review: Dockerfile Security Review"
section: "Interview"
order: 4
---

# PR Review: Dockerfile Security Review

## The Senior Engineer Frame

Most candidates can spot individual issues. Senior engineers ~**thematize**. The interviewer isn't testing whether you know `ADD` vs `COPY` — they're testing whether you see the pattern connecting 10 different findings into 3-4 root causes.

### The Four Axes of Dockerfile Review

Every finding maps to one of these:

1. **Integrity & Reproducibility** — Can this build be reliably reproduced? (tags vs digests, lockfiles, `npm ci`, hash verification)
2. **Least Privilege** — Does the container have only what it needs? (root user, capabilities, seccomp, read-only rootfs, exposed ports)
3. **Confidentiality** — Are secrets leaked anywhere? (build args, ENV in layers, `.dockerignore` gaps, intermediate layers)
4. **Transparency** — Can consumers verify what's in this image? (SBOM attestation, signing, OCI labels, provenance metadata)

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
