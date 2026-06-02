---
title: "Docker's Supply Chain Platform Strategy"
section: "Docker Product & Strategy"
order: 28
---

# Docker's Supply Chain Platform Strategy

## Overview

Docker is assembling the components of an end-to-end supply chain security platform. The thesis is that security must be embedded into every stage of the container lifecycle — from build to distribution to runtime — and that most organizations lack an integrated platform to achieve this. Docker's strategy is to provide that platform, deeply integrated with the developer workflow that made Docker ubiquitous.

The four pillars of the strategy are:

| Pillar | Product | Function |
|--------|---------|----------|
| **Build** | Docker Build Cloud | Fast, secure, multi-architecture builds |
| **Distribution** | Docker Hub | Image storage, organization management, access control |
| **Hardening** | Docker Hardened Images (DHI) | Trusted, attested base images |
| **Analysis** | Docker Scout | SBOM, vulnerability scanning, policy evaluation |

---

## How the Pillars Connect

The platform strategy is not about four separate products — it's about how they work together to create a cohesive supply chain.

### The Integrated Workflow

```
Developer → Dockerfile → Build Cloud → Docker Hub → Scout Analysis → Policy Gate → Production
                              │                              │
                              ↓                              ↓
                         DHI Base Image               Attestations + SBOM
```

1. **Developer starts with a DHI base image** — trusted, hardened, attested, with known provenance
2. **Build Cloud compiles the image** — multi-architecture, with provenance and SBOM attestations attached during the build
3. **Image is pushed to Docker Hub** — stored in private or org repository with access controls
4. **Scout analyzes the image** — generates SBOM, cross-references CVEs, evaluates against environment policies
5. **Policy gate decides** — if the image passes, it's tagged for production; if it fails, the deployment is blocked and the developer receives remediation guidance
6. **Runtime verification** — Scout continues to monitor images in production, alerting on new CVEs

### The "Docker-Native" Advantage

```bash
# A single workflow that touches all four pillars

# 1. Build from hardened base image
FROM docker/hardened-node:20
COPY . .
RUN npm ci --omit=dev

# 2. Build with Build Cloud (multi-arch + attestations)
docker buildx build \
  --builder cloud-org-builder \
  --platform linux/amd64,linux/arm64 \
  --sbom=true \
  --attest type=provenance,mode=max \
  -t myorg/my-app:latest \
  --push \
  .

# 3. Hub stores and distributes the image
# 4. Scout auto-analyzes (integrated with Hub)
# 5. Policy evaluation gates deployment
docker scout policy --env production myorg/my-app:latest
```

The integration is the product. No separate scanner setup, no external registry configuration, no additional signing infrastructure — it all works because Docker controls the entire pipeline.

---

## Competitive Landscape

Docker's strategy must be understood in the context of its competitors, each of which approaches supply chain security from a different angle.

### Chainguard

Chainguard is a supply chain security company founded in 2021 by former Google engineers (Dan Lorenc, Kim Lewandowski, Ville Aikas, Matt Moore) who built Sigstore, SLSA, in-toto, and distroless while at Google. The company's mission is to make software supply chain security available to every organization by building a complete, open-core platform for container image security.

**Product Stack:**

| Layer | Product | Description | Business Model |
|-------|---------|-------------|----------------|
| **OS** | Wolfi | A Linux distribution designed from scratch for containers. Custom-built from source, rebuilt near-daily. Proactive CVE patching — patches vulnerable packages rather than waiting for upstream. Uses `apk` (Alpine's package manager). | Open source (Apache 2.0) |
| **Images** | Chainguard Images | ~200+ minimal, distroless container images built on Wolfi — runtimes (Python, Go, Node.js, Java), databases (PostgreSQL, Redis, MongoDB), middleware (Nginx, Envoy, HAProxy), security tools (Kyverno, Falco, OPA), monitoring (Prometheus, Grafana). Every image ships with SBOM + SLSA provenance + vulnerability scan attestations. | Free tier (public pull, rate-limited) + commercial subscription (unlimited pull, enterprise SLA) |
| **Policy** | Chainguard Enforce | A Kubernetes admission controller and policy engine that verifies image attestations at deploy time. Enforces SLSA levels, required attestation types, allowed registries, and vulnerability thresholds. Provides a continuous audit trail of what images run where. | Commercial (SaaS + self-hosted) |

**How the layers connect:**

```
Wolfi (OS) ──builds──→ Chainguard Images (200+ pre-built images)
                            │
                            ↓
                     Kubernetes cluster
                            │
                    Chainguard Enforce (admission control)
                     - Verifies attestations
                     - Enforces policies
                     - Audits runtime
```

Wolfi is the foundation: a minimal, continuously-patched OS that produces zero-CVE base images. Chainguard Images are the packaged product: ready-to-use containers built from Wolfi with signed attestations. Chainguard Enforce is the platform layer: it checks those attestations at admission time, ensuring only approved images with valid provenance and acceptable CVEs reach production.

**Relationship to Docker's platform:**

Docker and Chainguard compete at multiple layers of the stack, but also cooperate at the OS layer:

| Layer | Docker | Chainguard | Relationship |
|-------|--------|------------|-------------|
| **OS** | Wolfi (via DHI) | Wolfi | **Coopetition**: Both use Wolfi. Docker doesn't maintain Wolfi — Chainguard does. Docker gets Wolfi's security posture without running an OS team. |
| **Images** | Docker Hardened Images (~25 curated) | Chainguard Images (~200+) | **Competition**: DHI has a smaller catalog with tighter Docker integration. Chainguard has breadth. |
| **Analysis** | Docker Scout | Chainguard Enforce | **Competition**: Both do SBOM-based policy evaluation. Scout is CLI/Hub-integrated; Enforce is admission-control-native. |
| **Registry** | Docker Hub | cgr.dev | **Competition**: Hub has massive distribution; cgr.dev is smaller but purpose-built for Chainguard Images. |
| **Build** | Docker Build Cloud | None | **No equivalent**: Chainguard has no managed build service. Build Cloud is a Docker-exclusive differentiator. |

The coopetition at the OS layer is notable: Docker Hardened Images are built on Wolfi (Chainguard's OS), yet the two companies compete at the image and policy layers. This mirrors the open-source pattern where upstream suppliers and platform integrators have overlapping but distinct roles — Chainguard maintains the raw materials, Docker integrates them into a developer workflow.

**Approach**: Build a better base image and toolchain (Wolfi, apk, Chainguard Images, Chainguard Enforce)

**Strengths**:
- **Image catalog breadth**: Chainguard has more language runtimes and middleware images than DHI
- **OS ownership**: Chainguard controls Wolfi end-to-end. CVE remediation happens in hours, not days
- **Open core**: Wolfi is Apache 2.0, apk is open source. Community contributions to Wolfi packages

**Weaknesses**:
- **Distribution**: cgr.dev has minimal traffic compared to Docker Hub. Most developers have never pulled from cgr.dev
- **Developer workflow**: Chainguard's tooling is Kubernetes/admission-controller focused. Docker has better CLI and IDE integration
- **Brand recognition**: Docker is a household name in containers; Chainguard is unknown outside security teams
- **Build service**: No managed build platform. Customers must use their own CI or a third-party build service

**Docker's response**: DHI uses Wolfi as its base OS, coopetition with Chainguard. Docker integrates Wolfi's security posture with Docker's distribution and developer experience advantages.

### Anchore

**Approach**: Vulnerability scanning and policy engine (Grype, Syft, Anchore Enterprise)

**Strengths**:
- **Grype/Syft are the most widely used open source scanner/SBOM tool**
- **Policy engine is mature**: Fine-grained, flexible policy definitions with multiple control points
- **Vendor-neutral**: Works with any registry, any build system, any orchestrator
- **Enterprise features**: RBAC, audit logging, compliance reporting

**Weaknesses**:
- No image registry, no build platform, no base images — pure analysis layer
- Developer experience is CLI-first, not pipeline-integrated
- Policy authoring requires YAML expertise; less accessible than Scout's environment-based model

**Docker's response**: Scout competes with Anchore Enterprise but is differentiated by being embedded in the Docker workflow. Scout policies are simpler to configure; the trade-off is less flexibility.

### Aqua Security

**Approach**: Cloud-native application protection platform (CNAPP) covering full lifecycle

**Strengths**:
- **Broadest product scope**: Image scanning, runtime protection, IaC scanning, Kubernetes security, vulnerability management
- **Enterprise maturity**: Role-based access control, SIEM integration, compliance reporting, incident response workflows
- **Deep runtime protection**: Not just pre-deployment scanning — Aqua monitors container behavior at runtime

**Weaknesses**:
- **Complexity**: CNAPP platforms require significant setup, configuration, and ongoing management
- **Developer friction**: Security gates are enforced by security teams, not developers
- **Cost**: Enterprise CNAPP licensing is expensive; overkill for smaller teams

**Docker's response**: Docker focuses on developer-friendly, pre-deployment security. Docker doesn't compete at the runtime level (no Kubernetes admission controller, no runtime monitoring). The strategy is to be the best-in-class supply chain platform for the build-to-deploy window, then integrate with runtime security providers.

### Red Hat

**Approach**: Enterprise container platform (UBI, Quay.io, OpenShift, ACS)

**Strengths**:
- **UBI is well-established**: RHEL-based, commercially supported, familiar to enterprise ops teams
- **Quay is a mature registry**: Geo-replication, security scanning, image mirroring
- **OpenShift integration**: End-to-end platform from build to orchestration
- **Red Hat Advanced Cluster Security (ACS)**: StackRox-based runtime security

**Weaknesses**:
- **RHEL dependency**: UBI images are larger and have a different CVE surface than Wolfi or Alpine
- **Cost center**: Red Hat subscriptions are expensive; UBI requires a Red Hat account for some features
- **Developer experience**: OpenShift and Quay are enterprise-focused; less accessible for individual developers

**Docker's response**: Docker competes on developer experience and lower cost. Docker Hub is free for public images and inexpensive for private; Build Cloud is consumption-based; DHI is commercially supported but doesn't require a platform subscription. Docker's bet is that developers will choose the path of least resistance.

---

## Docker's Differentiation

### 1. Developer Workflow Integration

Docker's single strongest advantage is that developers already use Docker. Scout commands use the same `docker` CLI they run daily. DHI images are pulled with the same `docker pull` command. There's no new tooling, no new workflows, no new login credentials. The security layer is invisible until it needs to be visible (policy violation, CVE alert).

### 2. Ease of Use

- Scout policies are environment-based (`--env production`), not complex Rego rules
- DHI images follow the same interface as official images (same env vars, same ports, same entrypoints)
- Build Cloud works with the existing `docker buildx` command
- Hub organization management is familiar to anyone who has used GitHub organizations

### 3. Multi-Platform Build

Build Cloud's ability to build for `linux/amd64`, `linux/arm64`, and `linux/arm/v7` in parallel is a genuine differentiator. No other supply chain platform offers native multi-architecture build infrastructure integrated with signing and analysis.

---

## Strategic Challenges

### Challenge 1: Platform Lock-In Perception

Docker's strategy only works if customers use multiple Docker products. A customer using Chainguard Images, Harbor registry, and Grype scanning is using none of Docker's platform. Docker needs to convince customers to consolidate.

**Mitigation**: Docker makes individual products valuable standalone (DHI without Scout, Scout without Hub). The platform value is additive, not gated.

### Challenge 2: Runtime Security Gap

Docker's platform stops at deployment. For runtime security, customers need Aqua, Sysdig, Falco, or a Kubernetes admission controller. Docker doesn't offer admission control, runtime monitoring, or incident response.

**Mitigation**: Docker positions itself as the build-to-deploy layer and partners with runtime security providers. The OCI standard for attestations enables runtime tools to verify Docker-signed images.

### Challenge 3: Open Source Competition

Grype/Syft (Anchore), Trivy (Aqua), cosign (Sigstore), and Wolfi (Chainguard) are all open source and widely adopted. Docker's products are proprietary (with some open source components). Open source tools are free, community-supported, and vendor-neutral.

**Mitigation**: Docker competes on integration, usability, and support. The open source tools are powerful but require assembly. Docker provides a pre-assembled, supported platform.

### Challenge 4: Enterprise Trust

Docker has a history of pricing changes (Docker Desktop licensing in 2021) that eroded enterprise trust. Security platform adoption requires trust. Enterprises worry about vendor lock-in, pricing changes, and long-term commitment.

**Mitigation**: Docker is building enterprise features (RBAC, audit logging, commercial SLAs) and communicating a clear product roadmap. DHI's enterprise SLA is a concrete example.

---

## Opportunities

### Opportunity 1: Supply Chain Regulations

Regulatory pressure is increasing: US Executive Order 14028, EU Cyber Resilience Act, FDA pre-market cybersecurity requirements. Organizations need to demonstrate supply chain security. Docker's platform provides attestation evidence that directly maps to regulatory requirements.

### Opportunity 2: AI/ML Image Security

As organizations deploy AI models in containers, they need the same supply chain guarantees. Docker can extend Scout to scan model files, Python dependencies, and CUDA toolkits. DHI can provide hardened base images for ML workflows (TensorFlow, PyTorch, NVIDIA CUDA).

### Opportunity 3: The "Docker Desktop" Distribution Channel

Every Docker Desktop installation is a potential Scout activation. Docker Desktop already includes Scout integration; expanding this to include DHI recommendations and Build Cloud integration creates a distribution channel that competitors can't match.

---

## Likely Interview Questions

- "How would you convince an organization using Chainguard Images + Harbor + Trivy to switch to Docker's platform?" (Focus on integration: one CLI, one registry, one analysis platform. The switch is from "assembling best-of-breed" to "running an integrated platform." Demonstrate Scout policy evaluation speed and Build Cloud build times.)
- "What's Docker's biggest supply chain security competitor?" (Chainguard — they compete on the same plane (base images + analysis + policy) with an open source foundation. Anchore and Aqua compete at different levels of the stack.)
- "Where would you invest next if you were leading Docker's supply chain strategy?" (Runtime verification integration — not a full runtime product, but attestation verification at admission control via a Kubernetes admission webhook. Also: AI/ML image support.)
- "How does Docker's platform strategy benefit a 10-person startup vs. a 10,000-person enterprise?" (Startup: zero-config Scout, free Hub, DHI base images — security out of the box. Enterprise: RBAC, org-level policies, commercial SLA, FIPS images, integration with existing CI/CD.)

For deeper dives into the underlying technologies that power Docker's platform, see [Docker Architecture](../articles/30-docker-architecture.md) and [BuildKit Internals](../articles/32-buildkit-internals.md).
