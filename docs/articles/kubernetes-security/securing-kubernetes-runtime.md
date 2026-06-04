---
title: "Securing the Kubernetes Runtime — Defense in Depth"
section: "Kubernetes Security"
order: 15
---

# Securing the Kubernetes Runtime — Defense in Depth

Kubernetes runtime security is a layered problem. An attacker who compromises one layer (a vulnerable container, a misconfigured RBAC role, an exposed API server) should be contained by controls at the next. This article surveys the built-in Kubernetes primitives and ecosystem tools available at each layer, from authentication down to runtime detection.

---

## Authentication & Authorization

### RBAC

RBAC is the primary authorization mechanism. Three resource types control access:

| Resource | Scope | Purpose |
|---|---|---|
| `Role` / `ClusterRole` | Namespace / Cluster | Defines allowed verbs (`get`, `create`, `delete`) on resources (`pods`, `deployments`, `secrets`) |
| `RoleBinding` / `ClusterRoleBinding` | Namespace / Cluster | Binds a subject (User, Group, ServiceAccount) to a Role/ClusterRole |

**Common anti-patterns:**

- **ClusterRoleBinding for namespace-scoped access.** A `RoleBinding` should reference a `Role`, not a `ClusterRole`, unless the pod genuinely needs cluster-wide access.
- **Using `default` ServiceAccount.** Every namespace has a `default` SA; workloads that don't need API access should set `automountServiceAccountToken: false`.
- **Overly permissive roles.** Wildcard verbs (`*`) on sensitive resources (`secrets`, `pods/exec`) grant far more than needed. Audit with `kubectl auth can-i --list --as=system:serviceaccount:ns:name`.

### ServiceAccount Hardening

Kubernetes 1.24+ generates **bound ServiceAccount tokens** (projected volume with audience, expiration, and pod binding) instead of static secrets. This limits token theft: a stolen bound token is valid only for its intended pod and audience.

```yaml
apiVersion: v1
kind: Pod
spec:
  serviceAccountName: my-app
  automountServiceAccountToken: false  # if no API access needed
  volumes:
    - name: token
      projected:
        sources:
          - serviceAccountToken:
              audience: "https://kubernetes.default.svc"
              expirationSeconds: 3600
```

Key settings: `--service-account-extend-token-expiration=false` (default in 1.28+) prevents indefinite token reuse.

### Authentication Methods

| Method | Use Case |
|---|---|
| OIDC | Human users via identity provider (Dex, Keycloak, Okta). Configured via `--oidc-*` flags on the API server. |
| Webhook token | Custom authentication for non-OIDC tokens (e.g., cloud IAM integration) |
| ServiceAccount tokens | Pod-to-API-server authentication. Automatic. |
| x509 client certs | Bootstrap and component-to-component. Hard to revoke; prefer OIDC for humans. |
| Anonymous auth | Off by default in 1.6+. `--anonymous-auth=false` in production. |

### Node Authorization

The kubelet authenticates as a member of the `system:nodes` group with the **Node authorizer**, which limits the kubelet to read its own pods, update its own node status, and write pod status events. This prevents a compromised kubelet from accessing other pods' data.

---

## Pod Security

### SecurityContext & PodSecurityContext

Pod security is configured at two levels:

- **PodSecurityContext** (`spec.securityContext`): pod-wide defaults — `runAsNonRoot`, `fsGroup`, `runAsUser`, `seccompProfile`, `selinuxOptions`. Cannot set capabilities or privileged mode.
- **SecurityContext** (`containers[].securityContext`): container-specific — `capabilities`, `privileged`, `readOnlyRootFilesystem`, `allowPrivilegeEscalation`. Overrides pod-level `runAsUser` etc. for that container.

**Cascade rule:** Pod-level values apply to all containers unless the container explicitly overrides. `fsGroup` and `supplementalGroups` are always pod-level only.

### Pod Security Standards (PSS)

| Level | Description | Key Restrictions |
|---|---|---|
| **Privileged** | Unrestricted | None. For infrastructure components (CNI, storage drivers). |
| **Baseline** | Prevents known privilege escalations | No privileged containers, no host namespaces, no HostPath, no `SYS_ADMIN`, limited sysctls, restricted capability additions. |
| **Restricted** | Hardened for security-critical workloads | All Baseline + `runAsNonRoot: true`, `capabilities.drop: ["ALL"]`, `seccomp: RuntimeDefault`, `allowPrivilegeEscalation: false`, `readOnlyRootFilesystem: true`. |

### Pod Security Admission (PSA)

PSA enforces PSS via namespace labels (built-in admission controller, GA in 1.25):

```yaml
labels:
  pod-security.kubernetes.io/enforce: restricted
  pod-security.kubernetes.io/audit: baseline
  pod-security.kubernetes.io/warn: restricted
```

Three modes — **enforce** (block), **audit** (log), **warn** (return warning). Gradual rollout: warn → audit → enforce. Version pinning via `enforce-version: v1.28` prevents new checks from breaking existing workloads on upgrade.

PSA replaced PodSecurityPolicy (PSP, removed in 1.25). PSA is simpler but cannot express fine-grained policies — use Kyverno or OPA for that.

### Linux Capabilities

Containers start with a default set (~15 capabilities). Hardened pattern:

```yaml
securityContext:
  capabilities:
    drop: ["ALL"]
    add: ["NET_BIND_SERVICE"]  # only what is needed
  allowPrivilegeEscalation: false
```

Common dangerous capabilities: `SYS_ADMIN` (namespace escape), `NET_ADMIN` (network manipulation), `SYS_PTRACE` (process introspection). Never add these in multi-tenant clusters.

### Seccomp

```
RuntimeDefault: blocks ~50% of syscalls. Suitable for most workloads.
Localhost: custom profile for specific applications.
Unconfined: all syscalls. Never in production.
```

Seccomp is set via `securityContext.seccompProfile.type`. PSA Restricted requires `RuntimeDefault` or `Localhost`.

### readOnlyRootFilesystem

Prevents binary downloads, log tampering, and unauthorized file writes. See the dedicated [Read-only Filesystems](../container-image-hardening/readonly-filesystem.md) article for a deep dive on attack scenarios, app breakage patterns, and Helm integration. Mount `emptyDir` volumes for write paths:

```yaml
securityContext:
  readOnlyRootFilesystem: true
volumeMounts:
  - name: tmp
    mountPath: /tmp
volumes:
  - name: tmp
    emptyDir: {}
```

---

## Network Security

### NetworkPolicy

NetworkPolicy is a Kubernetes-native firewall. By default, all pods can communicate with all other pods. A policy activates rules for the pods it selects.

**Common pattern: default deny + allow specific:**

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-ingress
spec:
  podSelector: {}
  policyTypes:
    - Ingress
---
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-app-ingress
spec:
  podSelector:
    matchLabels:
      app: my-service
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: frontend
      ports:
        - port: 8080
```

**Key considerations:**

- **CNI support:** Flannel does not support NetworkPolicy. Calico, Cilium, Weave, and Antrea do. Cilium adds L7-aware policies, DNS-based rules, and Hubble for network visibility.
- **Egress policies:** Often forgotten. Default deny egress prevents data exfiltration if a pod is compromised.
- **ipBlock:** Restrict external access; e.g., only allow egress to specific CIDR ranges for API calls.

### Encryption in Transit

- **Kubelet TLS:** `--kubelet-certificate-authority`, `--kubelet-client-certificate` ensure API-server-to-kubelet TLS.
- **etcd TLS:** Client-to-etcd and peer-to-peer TLS. `--peer-client-cert-auth`, `--peer-auto-tls=false`.
- **Service mesh:** Istio, Linkerd, and Cilium provide mTLS between pods transparently. Cilium uses eBPF for per-pod identity with no sidecar overhead.

---

## Secrets Management

### etcd Encryption at Rest

Secrets are base64-encoded in etcd by default — not encrypted. Enable encryption at rest via `EncryptionConfiguration`:

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - kms:
          name: myKMS
          endpoint: unix:///var/run/kms-plugin/socket.sock
      - aesgcm:
          keys:
            - name: key1
              secret: c2VjcmV0IGlzIHNlY3VyZQ==
      - identity: {}  # fallback for reading existing unencrypted secrets
```

**Best practice:** Use `kms` provider (cloud KMS, Vault, AWS KMS) over `aesgcm` or `secretbox`. KMS provides key rotation, access auditing, and HSM backing. `identity` should be last as a read-only fallback.

### Secret Distribution

| Method | etcd Stores Secret? | Best For |
|---|---|---|
| Kubernetes Secret | Yes | Quick prototyping, bootstrapping |
| External Secrets Operator | Yes (syncs from external store) | Bridging external stores to K8s |
| CSI Secret Store | **No** (mounts directly) | Production — secret never in etcd |

**Never:** supply Secrets as environment variables — they leak into pod specs, `/env` endpoints, shell history, and audit logs. Use volume mounts or projected volumes.

### Bound ServiceAccount Tokens

Projected service account tokens (GA in 1.21) are **time-bound, audience-scoped, and pod-bound**. Unlike static secrets, a token stolen from one pod cannot be used from another. Configure via projected volume:

```yaml
volumes:
  - name: token
    projected:
      sources:
        - serviceAccountToken:
            audience: "vault"
            expirationSeconds: 600
```

---

## API Server Hardening

### Admission Controllers

Built-in controllers run before webhooks. Key ones:

| Controller | Purpose |
|---|---|
| `NamespaceLifecycle` | Prevents creating resources in deleting namespaces |
| `NodeRestriction` | Limits kubelet's self-mutation |
| `PodSecurity` | Enforces PSS (replaces PSP) |
| `ServiceAccount` | Creates SA and token automatically |

**Webhooks** (mutating + validating) run after built-in controllers. Mutating runs before validating. Webhook `failurePolicy: Fail` ensures enforcement doesn't silently lapse if the webhook is down.

### Audit Logging

Audit logs are the record of every API request. Configure via `--audit-policy-file`:

```yaml
apiVersion: audit.k8s.io/v1
kind: Policy
rules:
  - level: RequestResponse
    verbs: ["create", "update", "patch", "delete"]
    resources:
      - group: ""
        resources: ["secrets", "pods", "configmaps"]
  - level: Metadata
    userGroups: ["system:authenticated"]
  - level: None
    userGroups: ["system:nodes"]
```

Stages: `RequestReceived`, `ResponseStarted`, `ResponseComplete`, `Panic`. Levels: `None`, `Metadata`, `Request`, `RequestResponse`. Route to a sidecar or external sink for retention and alerting.

### Encryption Config

`--encryption-provider-config` controls at-rest encryption for resources in etcd (Secrets, ConfigMaps, etc.). Rotate keys periodically. With KMS provider, key rotation is a provider call — no API server restart needed.

### TLS Hardening

```
--tls-min-version: VersionTLS12
--tls-cipher-suites: TLS_ECDHE_RSA_WITH_AES_128_GCM_SHA256,...
```

Disable insecure cipher suites. Rotate serving certificates before expiry (kubelet and API server).

---

## Node & Control Plane Security

### Kubelet Hardening

The kubelet exposes an API on two ports. Secure them:

```
--read-only-port=0          # Disable unauthenticated port 10255
--authentication.anonymous.enabled=false
--authorization.mode=Webhook
--protect-kernel-defaults=true
```

`--protect-kernel-defaults` ensures the kubelet enforces sysctl hardening (e.g., `net.ipv4.conf.all.forwarding=0`). Without it, containers could modify kernel parameters.

### Metadata Service Blocking

Cloud provider metadata services (AWS `169.254.169.254`, GCE `metadata.google.internal`) grant access to instance credentials. Block via:

- **NetworkPolicy** for egress to the metadata IP
- **Calico/Cilium** host-endpoint policies to block before pod networking
- **IMDSv2** with hop limit on EC2
- **GKE metadata concealment** (blocks VM metadata from pods)

### Control Plane Isolation

- Taint control plane nodes (`node-role.kubernetes.io/control-plane:NoSchedule`)
- Don't run user workloads on control plane nodes
- Restrict access to etcd (`--peer-client-cert-auth`, firewall to apiserver only)
- Use dedicated nodes for system components (kube-system pods)

### CIS Benchmark & kube-bench

[kube-bench](https://github.com/aquasecurity/kube-bench) automates CIS Kubernetes Benchmark checks. Run it against each cluster component:

```bash
# On control plane node
kube-bench --config-dir /etc/kube-bench/cfg --benchmark cis-1.8

# As a CronJob in the cluster
kubectl apply -f https://raw.githubusercontent.com/aquasecurity/kube-bench/main/job.yaml
```

Key CIS controls: API server anonymous auth disabled, etcd peer cert auth, kubelet anonymous auth disabled, kubeconfig file permissions 600, controller manager `--use-service-account-credentials`.

### Immutable OS

Flatcar, Bottlerocket, and COS (Container-Optimized OS) reduce node attack surface by eliminating package managers, read-only root filesystems, and automatic updates. Bottlerocket's API is a single lockbox endpoint — no SSH by default.

---

## Runtime Detection

### Falco

Falco uses eBPF or a kernel module to intercept syscalls and match them against rules. It is CRI-aware — it knows about pods, containers, and Kubernetes metadata.

**Example rules triggered by a compromised container:**

- Shell spawns inside a container not built with a shell
- Unexpected outbound network connection to a known-bad IP
- Read of `/etc/shadow` or `/root/.ssh/id_rsa`
- `setuid` binary execution with no-new-privs
- Privilege escalation via `userfaultfd` or `memfd_create`

Falcosidekick routes alerts to Slack, Loki, PagerDuty, or webhooks. Falco Talon adds automated response: kill pod, exec debug container, capture filesystem snapshot.

### Admission Policy Engines

**Kyverno** is Kubernetes-native (policies as CRDs). It can mutate, validate, or generate resources. Key security policies:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-drop-all-capabilities
spec:
  validationFailureAction: Enforce
  rules:
    - name: check-containers
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "All containers must drop ALL capabilities."
        pattern:
          spec:
            containers:
              - securityContext:
                  capabilities:
                    drop: ["ALL"]
```

**OPA/Gatekeeper** uses Rego, a more expressive policy language, but has a steeper learning curve. Both support audit-only mode, background scanning, and policy reports.

### Synergy

- **Admission policies** (Kyverno/OPA) prevent bad configs from being deployed
- **PSA** blocks pods that violate PSS at admission (built-in, no CRDs)
- **Falco** catches runtime anomalies that admission could not (e.g., compromised image with a known-good config)

---

## Supply Chain at Runtime

### Image Verification at Admission

Built-in option: **ImagePolicyWebhook** — a simple admission webhook that validates image references against an external policy. Limited compared to ecosystem tools.

**Kyverno `verifyImages`** supports cosign verification, including keyless (Fulcio + Rekor):

```yaml
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
        - imageReferences:
            - "registry.io/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      ...
```

**Ratify** (CNCF sandbox) is a more flexible verification framework that supports notation, cosign, license checks, and custom verifiers. Designed for the `notation` ecosystem and pluggable verifier architecture.

**Binary Authorization** (GKE only) enforces deploy-time attestation: only images with valid attestations from trusted signers can be deployed. Integrates with Cloud Build, Artifact Registry, and external CI/CD.

### Webhook Risk

If an admission webhook is unreachable, `failurePolicy: Fail` blocks all pod creation — including system pods. Use `failurePolicy: Ignore` with caution (it silently skips verification). Monitor webhook health and deploy webhooks with high availability (multiple replicas, pod anti-affinity).

---

## Summary: Defense in Depth Layers

| Layer | Primitive / Tool | What It Prevents |
|---|---|---|
| Authentication | OIDC, Webhook, x509 | Unauthorized API access |
| Authorization | RBAC, Node authorizer | Privilege escalation via API |
| Pod Security | SecurityContext, PSS, PSA | Container breakout, privilege escalation |
| Network | NetworkPolicy, mTLS | Lateral movement, data exfiltration |
| Secrets | EncryptionConfig, CSI Store | etcd compromise leads to secret exposure |
| API Server | Admission webhooks, audit | Misconfigured or malicious workload admission |
| Node | kube-bench, immutable OS, taints | Node compromise via kubelet |
| Runtime | Falco, Kyverno/OPA | Post-compromise detection and response |
| Supply Chain | Cosign, Ratify, Binary Auth | Untrusted image deployment |

No single control is sufficient. The goal is to force an attacker to defeat multiple layers to achieve cluster compromise.
