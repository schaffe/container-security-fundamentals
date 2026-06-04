---
title: "Key Kubernetes Ecosystem Tools"
section: "Kubernetes Security"
order: 14
---

# Key Kubernetes Ecosystem Tools

Several ecosystem tools appear throughout the Kubernetes Security articles. This page provides a quick reference for each — what it is, why it matters for security, and where it's discussed in detail.

---

## cert-manager

**What it is:** A Kubernetes add-on that automates the lifecycle of TLS certificates. It issues, renews, and rotates certificates from a variety of issuers — Let's Encrypt, HashiCorp Vault, Venafi, AWS Private CA, and self-signed CAs. It manages certificates via Kubernetes CRDs: `Certificate`, `Issuer`, `ClusterIssuer`, and `CertificateRequest`.

**Role in security:** cert-manager enables automatic mTLS for pod-to-pod communication, ingress TLS termination, and CA-based identity. Without it, certificate rotation is manual and often neglected, leading to expired certs or long-lived keys.

**In this project:** Referenced in [Adapting Upstream Helm Charts](adapting-upstream-helm-charts.md) as a chart that requires careful security context adaptation — its `cainjector` component historically needed privileged mode but modern versions work under Restricted.

**Resources:** cert-manager.io

---

## Kyverno

**What it is:** A Kubernetes-native policy engine that validates, mutates, and generates Kubernetes resources. Policies are defined as CRDs, not in a separate language — a `ClusterPolicy` resource uses YAML-based `match`/`validate`/`mutate` rules. This makes it more approachable than OPA/Gatekeeper (which uses Rego).

**Role in security:** Kyverno is the most commonly cited admission controller for supply chain security. Its `verifyImages` rule enforces that only signed images (via Cosign, Notation, or custom attestors) can be deployed. It also enforces Pod Security Standards, blocks dangerous capabilities, requires resource limits, and can audit existing resources via background scans.

**Key capabilities:**

- **Verify images at admission** — check Cosign signatures, attestations, SBOMs
- **Mutate resources** — inject sidecars, set default security contexts
- **Generate resources** — create NetworkPolicies or Secrets based on namespace labels
- **Audit mode** — report violations without blocking (for gradual rollout)

**In this project:** Discussed extensively in [Admission Control](admission-control.md) and [Securing the Kubernetes Runtime](securing-kubernetes-runtime.md). Also appears in interview articles on hardened image build pipelines and image signing.

**Resources:** kyverno.io

---

## Grafana

**What it is:** An open-source observability platform for metrics, logs, and traces. It queries data sources (Prometheus, Loki, Tempo, CloudWatch, etc.) and renders dashboards, alerts, and reports. In Kubernetes, Grafana is typically deployed via Helm chart alongside Prometheus (kube-prometheus-stack).

**Role in security:** Grafana is a **consumer** of security data — it visualizes Falco alerts, admission policy reports, CVE scan results, and cluster audit logs. It does not enforce security itself, but is essential for detection and response.

**In this project:** Referenced in [Adapting Upstream Helm Charts](adapting-upstream-helm-charts.md) as a real-world example of hardening — it needs writable paths at `/var/lib/grafana`, `/var/log/grafana`, `/var/lib/grafana/plugins`, and `/tmp` that must be mapped to `emptyDir` volumes when `readOnlyRootFilesystem: true`. Also listed as a Docker Hardened Image catalog entry.

**Resources:** grafana.com

---

## Istio

**What it is:** A service mesh that injects Envoy sidecar proxies into pods to handle inter-service communication. It provides traffic management (routing, retries, circuit breaking), observability (metrics, tracing, access logs), and security (mTLS, authorization policies) — all at the platform layer, without application code changes.

**Role in security:** Istio's primary security contribution is **automatic mTLS** — it encrypts and authenticates all pod-to-pod traffic using SPIFFE identities, without application modification. It also supports authorization policies (`AuthorizationPolicy` CRD) for L7 access control, and peer authentication for mTLS mode configuration (STRICT, PERMISSIVE, DISABLE).

**Security considerations:**

- Sidecar injection adds a container to every pod — each sidecar must be hardened (drop capabilities, read-only rootfs)
- Istio itself is a high-value target — the control plane (istiod) must be in a privileged namespace with restricted access
- mTLS does not prevent application-level attacks — it secures the transport, not the data

**In this project:** Referenced in [Securing the Kubernetes Runtime](securing-kubernetes-runtime.md) as an option for L7 mTLS between pods (alongside Linkerd and Cilium). Not covered in depth elsewhere.

**Resources:** istio.io

---

## Comparison at a Glance

| Tool | Category | Security Role | CRDs? | Policy Language |
|---|---|---|---|---|
| cert-manager | Certificate lifecycle | Automatic TLS/mTLS | Yes | YAML (CRD fields) |
| Kyverno | Policy engine | Admission control, image verification | Yes | YAML (rules) |
| Grafana | Observability | Security visualization | No | N/A (dashboard config) |
| Istio | Service mesh | mTLS, authz policies | Yes | YAML (CRD fields) |
