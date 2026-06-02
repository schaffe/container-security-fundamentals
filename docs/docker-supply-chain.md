# Docker Supply Chain

## Topic Map

### 1. Supply Chain Security Theory

- **SLSA framework:** L1–L4 levels, requirements per level. Provenance generation, hermetic builds, reproducibility. Map existing L3 pipeline: what attestations, build platform, verification chain, trust domain. What would L4 require (two-person review, no untrusted inputs, reproducibility)? L4 is aspirational even at Google.
- **In-toto attestations:** Predicate types — SLSA Provenance (v0.2/v1), test result, vuln scan, code review. Attestation bundle format (DSSE + in-toto statement + predicate). Link to cosign `attest` command.
- **SBOM:** CycloneDX vs SPDX formats. Generation with Syft, Trivy, Docker Scout. Consumption: vulnerability matching via Grype, Trivy, OSV. VEX documents (Vulnerability Exploitability eXchange) for communicating "not affected" decisions. Relationship between SBOM and attestation.
- **Sigstore:** cosign (sign, verify, attest, verify-attestation), Fulcio (ephemeral certificates via OIDC), Rekor (transparency log), keyless vs key-based signing. Signing identities based on OIDC (email, SPIFFE). Bundle format for offline verification.
- **Dependency management security:** Dependency confusion, typosquatting, repo-jacking. Hash pinning (exact) vs version pinning (semver) vs range pinning — security vs maintainability trade-offs. Lockfile security. Package manager-specific risks (npm postinstall, pip setup.py, apt install scripts).
- **Trusted builds:** Build platform security. Non-build platform cannot sign. Air-gapped signing, HSM/TEE-backed keys, threshold signing. SLSA's build platform requirements.
- **Notary / Docker Content Trust:** TUF (The Update Framework) — root, targets, snapshot, timestamp key hierarchy. Delegation roles. Why Docker is investing in both Notary v2 and Sigstore integration.

### 2. Linux Fundamentals

- **musl vs glibc:** How the two C standard libraries compare (size, POSIX compliance, static linking, CVE history). Compatibility pitfalls: glibc-specific APIs, DNS resolution differences, locale support. Security decision framework for choosing between musl (Alpine) and glibc (Debian, Ubuntu, distroless) base images.

### 3. Container Image Hardening

- **Distroless images:** What they exclude (shell, package manager, setuid binaries, common Unix tools — cp, tar, vi). Attack surface comparison: distroless (~5 packages) vs Alpine (~30) vs Ubuntu (~150). When distroless breaks: health checks needing shell, runtime package installs, debugging. Mitigations: debug image variants, static binaries.
- **Image minimization:** Multi-stage build patterns. COPY --from for binary-only result. RUN cleanup chains (`rm -rf /var/lib/apt/lists/*`), layer squash (`--squash`). Stripping binaries, removing shared libraries not needed at runtime.
- **Non-root execution:** USER directive, UID/GID allocation (common patterns: 10001, 65534/nobody). `--security-opt=no-new-privileges:true`. Implications for port binding (>1024 needed).
- **Linux capabilities:** Full list of ~40 capabilities. `--cap-drop=ALL --cap-add=CHOWN --cap-add=NET_BIND_SERVICE` as common hardened pattern. What each capability enables and the risk. Ambient capabilities for non-root.
- **Seccomp:** Docker's default seccomp profile (blocked ~300 of ~450 syscalls). RuntimeDefault vs custom profiles. Common blocked syscalls: `mount`, `umount`, `ptrace`, `swapon`, `kexec_load`. Writing custom profiles for specific applications.
- **AppArmor / SELinux:** Per-container profiles. docker-default AppArmor profile. SELinux type enforcement (svirt_lxc_net_t). How they interact with seccomp and capabilities. K8s SecurityContext fields for AppArmor/SELinux.
- **Read-only filesystem:** `readOnlyRootFilesystem: true` in SecurityContext. Mount tmpfs for write locations (`/tmp`, `/var/run`, `/var/log`, `/var/cache/nginx`). What applications break (need to write to /etc, /var/lib).
- **Multi-arch security:** `FROM --platform=$BUILDPLATFORM` in multi-stage. Per-arch base images (arm64 vs amd64) have different CVE profiles. Registries with multi-arch manifests, attestation per-architecture.

### 4. Helm Chart Security Adaptation

- **SecurityContext vs PodSecurityContext:** SecurityContext on container (container-level settings: capabilities, runAsUser, readOnlyRootFS, seccomp). PodSecurityContext on pod (pod-level: fsGroup, runAsNonRoot, supplementalGroups, seLinuxOptions, sysctls). Cascade behavior: pod-level defaults overrideable at container level.
- **Pod Security Standards:** Three policies — privileged (no restrictions), baseline (minimal, prevents known privilege escalations), restricted (hardened, follows pod hardening best practices). What each allows/blocks:
  - **Baseline:** No hostPID, no hostNetwork, no hostIPC, no privileged containers, no hostPath volumes, no CAP_SYS_ADMIN
  - **Restricted:** All baseline + must run as non-root, must drop ALL capabilities, readOnlyRootFS=true (unless mount needed), seccomp RuntimeDefault, no allowPrivilegeEscalation
- **Adapting upstream charts:** Common breaking changes when making restricted:
  - Containers running as root → add `runAsUser: <non-root>` and ensure image supports it
  - Init containers needing `NET_ADMIN` or `SYS_ADMIN` → redesign or use restricted subset
  - Port binding below 1024 → remap to >1024
  - Volume writes → readOnlyRootFS + explicit emptyDir for write locations
  - Liveness/readiness probes needing shell (`command: ["sh", "-c"]`) → rewrite as HTTP/TCP/gRPC probes or use static binary
  - `securityContext.privileged: true` → remove, restructure
- **Admission control:** Kyverno `verifyImages` rule for enforcing signed images. OPA/Gatekeeper constraints for Pod Security Standards. Pod Security Admission (native in K8s 1.23+, GA in 1.25). Enforce vs audit vs warn mode.

### 5. CVE Lifecycle

- **Scanner internals:**
  - **Trivy:** OS package DB (Alpine secdb, RedHat OVAL, Debian SSA, Ubuntu USN) + language-specific (npm, pip, gem, go, cargo, maven). Fast, widely adopted.
  - **Grype:** Anchore's scanner. Similar to Trivy but uses different vulnerability DB (GHSA + NVD + RedHat + Ubuntu + Alpine). Deeper library matching for some ecosystems.
  - **Docker Scout:** SBOM-first approach. Generates CycloneDX SBOM, matches against multiple DBs. Policy evaluation (fixable, severity threshold, package type). Integrated with Docker Hub and CLI.
  - **Comparison:** All three catch ~same set of known CVEs. Key differences: SBOM workflow (Scout), speed (Trivy), library depth (Grype for Python/Java). Use multiple for defense in depth.
- **CVE sources:** NVD (comprehensive, slow to update), GHSA (faster, GitHub-focused), OSV (Google, cross-ecosystem, API-first), RedHat OVAL (RHEL-specific, backport info). Each has different coverage windows.
- **CVSS 3.1 / 4.0:** Base Score (AV/AC/PR/UI/S/C/I/A), Temporal, Environmental. Differences in v4 (new metrics: Attack Requirements, Safety impact, Automatable). EPSS (Exploit Prediction Scoring System) — probability of exploitation, used alongside CVSS for prioritization.
- **Fix categorization:** Fixable (patch available, just upgrade) vs unfixable (upstream won't fix, wontfix, or no patch). OS-package CVEs (libc, openssl) vs language-library CVEs (log4j, lodash). Backport patches (vendor fixes without version bump) vs rebase to latest.
- **Coordinated disclosure:** Embargo period, reporter coordination, customer notification. Docker's vulnerability reporting process.

### 6. Docker Product & Strategy

- **Docker Scout:** SBOM generation (`docker scout sbom`), environment-based policy evaluation (`docker scout policy`, `docker scout recommendations`), attestation management (`docker scout attestation`), integration with Docker Hub and GitHub Actions.
- **Docker Hardened Images (DHI):** What's in the catalog (Postgres, Nginx, Redis, Grafana, cert-manager, Kyverno, MongoDB, and more). Build pipeline: SLSA L3, BuildKit, multi-arch, cosign + attestations, regular CVE scanning. How DHI differs from Docker Official Images (stricter hardening, enterprise SLAs, FIPS options).
- **Docker Content Trust / Notary v2:** Signing workflow, key hierarchy (root key offline, targets key online, snapshot/timestamp keys). Delegation roles for team signing. v2 improvements over v1.
- **Docker's supply chain platform:** How DHI (hardened images) + Scout (analysis/visibility) + Hub (distribution) + Build Cloud (build platform) form an end-to-end supply chain security platform. Competitive landscape:
  - **Chainguard:** Supply chain security company (founded 2021, ex-Google). Wolfi OS, Chainguard Images (~200+ minimal images), Chainguard Enforce (admission control policy). Direct competitor to DHI, Scout, and Hub; coopetition at Wolfi layer.
  - **Anchore:** Enterprise policy engine, Grype scanner, SBOM management. Competes with Scout.
  - **Aqua Security:** CSPM, CNAPP, runtime protection. Docker competes on developer workflow integration.
  - **Red Hat:** UBI images, Quay registry. Docker competes on ease of use and multi-platform.

## Interview Question Patterns to Expect

1. **System design:** Design a hardened image build pipeline, a CVE triage system, an image signing and verification workflow
2. **CVE scenario:** Given a specific CVE, walk through triage, fix strategy, customer communication
3. **Helm chart security review:** Given a Helm chart, identify security issues and fix them
4. **SLSA walkthrough:** "Tell me about the SLSA L3 pipeline you built" — architecture, trade-offs, attestation format
5. **Go coding:** Write a test that deploys a chart to a real K8s cluster and validates behavior
6. **Docker strategy:** How should Docker position DHI vs Chainguard? How would you improve the developer experience?
7. **Supply chain design:** Design a system that signs images, verifies at deploy time, and handles key compromise

## Resources

- **SLSA:** slsa.dev — framework docs, attestation format, threat model
- **Sigstore:** sigstore.dev — cosign docs, Fulcio, Rekor
- **Docker Scout docs:** docs.docker.com/scout/
- **Docker Hardened Images:** hub.docker.com — explore DHI catalog
- **Trivy:** github.com/aquasecurity/trivy — hands-on scanning
- **Helm security:** helm.sh/docs/topics/security/ plus real upstream charts (cert-manager, Grafana)
- **Pod Security Standards:** kubernetes.io/docs/concepts/security/pod-security-standards/
