---
title: "Admission Control for Supply Chain Security"
section: "Helm Chart Security Adaptation"
order: 19
---

# Admission Control for Supply Chain Security

Admission control is the gatekeeper of the Kubernetes API server. It intercepts requests **after** authentication and authorization but **before** persistence. For supply chain security, admission controllers enforce that only trusted, signed, and correctly configured images and workloads can run in the cluster.

## The Three-Layer Model

A defense-in-depth admission strategy uses three layers:

| Layer | Tool | Purpose |
|---|---|---|
| 1. Built-in validations | Pod Security Admission | Enforce PSS levels (`restricted`, `baseline`) |
| 2. Image verification | Kyverno / OPA + Ratify | Enforce signed images, SBOM validation, registry provenance |
| 3. Custom policies | Kyverno / OPA Gatekeeper | Enforce organization-specific rules (e.g., no latest tags, require resource limits) |

## Pod Security Admission (Native)

PSA is a built-in admission controller in K8s 1.23+ (GA in 1.25). It evaluates pods against PSS levels using namespace labels.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/enforce-version: v1.30
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

### Modes Explained

| Mode | Effect | Use Case |
|---|---|---|
| **Enforce** | Pod is rejected at admission if it violates the policy | Production namespaces |
| **Audit** | Pod is created, violation recorded in audit log events | Staging, gradual rollout |
| **Warn** | Pod is created, user gets an API warning response | Developer feedback during migration |

## Kyverno: Image Verification

Kyverno is a Kubernetes-native policy engine that validates and mutating admission requests. For supply chain security, its `verifyImages` rule is the most important capability.

### Verifying Cosign Signatures

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-image-signature
spec:
  validationFailureAction: Enforce
  webhookTimeoutSeconds: 30
  rules:
    - name: verify-cosign-signature
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "private.registry.example.com/*"
          attestors:
            - count: 1
              entries:
                - keys:
                    publicKeys: |-
                      -----BEGIN PUBLIC KEY-----
                      MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDAgA12345...
                      -----END PUBLIC KEY-----
          verifyDigest: true
          required: true
          mutations:
            - setImagePullSecrets:
                - name: regcred
```

This policy:
- Matches all Pods (including init containers and ephemeral containers)
- Checks that images from `private.registry.example.com` have a valid Cosign signature
- Rejects the pod if the signature is missing or invalid (`validationFailureAction: Enforce`)
- Ensures the image reference includes a digest (`verifyDigest: true`)
- Injects image pull secrets if needed

### Checking Image Age and Vulnerability Data

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-age
spec:
  validationFailureAction: Enforce
  rules:
    - name: reject-old-images
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Image must have been built within the last 30 days."
        foreach:
          - list: "request.object.spec.[initContainers, containers]"
            deny:
              conditions:
                all:
                  - key: "{{ age('{{ images.containers.{{ element.name }}.timestamp }}', '') }}"
                    operator: GreaterThan
                    value: 720h  # 30 days in hours
```

### Requiring Specific Image Registries

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: restrict-image-registries
spec:
  validationFailureAction: Enforce
  rules:
    - name: allowed-registries
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Images must originate from an approved registry."
        foreach:
          - list: "request.object.spec.[ephemeralContainers, initContainers, containers]"
            deny:
              conditions:
                all:
                  - key: "{{ images.containers.{{ element.name }}.registry }}"
                    operator: NotEquals
                    value: "private.registry.example.com"
```

### No-Latest-Tag Policy

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: require-image-tag
spec:
  validationFailureAction: Enforce
  rules:
    - name: require-tag-not-latest
      match:
        any:
          - resources:
              kinds:
                - Pod
      validate:
        message: "Using 'latest' tag is not allowed."
        pattern:
          spec:
            containers:
              - image: "!*:latest"
```

## OPA Gatekeeper: Constraint Templates for PSS

Gatekeeper uses the OPA constraint framework. Below is a `K8sRequiredLabels` style template adapted for PSS enforcement.

### Constraint Template: Require runAsNonRoot

```yaml
apiVersion: templates.gatekeeper.sh/v1
kind: ConstraintTemplate
metadata:
  name: k8srequirednonroot
spec:
  crd:
    spec:
      names:
        kind: K8sRequiredNonRoot
  targets:
    - target: admission.k8s.gatekeeper.sh
      rego: |
        package k8srequirednonroot

        violation[{"msg": msg}] {
          container := input.review.object.spec.containers[_]
          not container.securityContext.runAsNonRoot
          msg := sprintf("Container %v must set runAsNonRoot: true", [container.name])
        }
```

### Instantiate the Constraint

```yaml
apiVersion: constraints.gatekeeper.sh/v1beta1
kind: K8sRequiredNonRoot
metadata:
  name: require-nonroot
spec:
  match:
    kinds:
      - apiGroups: [""]
        kinds: ["Pod"]
    namespaces:
      - "production"
```

## Enforce vs Audit vs Warn: Where to Use Each

```
                   Enforce        Audit           Warn
                  ┌──────────────┬──────────────┬──────────────┐
  Production      │ [PSA] ✓      │ [Kyverno] ✓  │ [Gatekeeper] │
                  │ [PSS level]  │ [image sigs] │ [compliance] │
                  ├──────────────┼──────────────┼──────────────┤
  Staging         │              │ [PSA] ✓      │ [PSA] ✓      │
                  │              │ [Kyverno] ✓  │              │
                  ├──────────────┼──────────────┼──────────────┤
  Dev             │              │              │ [PSA] ✓      │
                  │              │              │ [Kyverno] ✓  │
                  └──────────────┴──────────────┴──────────────┘
```

Best practice: enforce the final policy in production, audit everything that can be audited, and warn developers early in the pipeline.

## Image Verification at Deploy Time

The verification flow:

1. Developer pushes an image to the registry with `cosign sign`
2. Kubernetes scheduler schedules a pod
3. API server intercepts via ValidatingWebhookConfiguration
4. Admission controller (Kyverno/Gatekeeper) inspects:
   - Image registry
   - Cosign signature (valid? signed by trusted key?)
   - Attestations (SBOM, provenance)
   - Image digest (not a mutable tag)
5. If all checks pass → pod is admitted
6. If checks fail → pod is rejected with a clear error message

## Combining Kyverno and Ratify for Notary Verification

For environments using Notation (Notary v2) instead of Cosign:

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: verify-notation-signature
spec:
  validationFailureAction: Enforce
  rules:
    - name: verify-notation
      match:
        any:
          - resources:
              kinds:
                - Pod
      verifyImages:
        - imageReferences:
            - "*"
          attestors:
            - entries:
                - keys:
                    notary: true
          repository: "private.registry.example.com"
```

## Best Practices for Admission Control

1. **Start with audit/warn**, never enforce first. You will break things.
2. **Pin policy versions**: Use `enforce-version: v1.30` to avoid regression on K8s upgrades.
3. **Exempt system namespaces**: `kube-system`, `gatekeeper-system`, `kyverno` must run privileged.
4. **Fail-closed webhooks**: Set `failurePolicy: Fail` for critical policies, `failurePolicy: Ignore` for non-critical.
5. **Monitor webhook latency**: Admission webhooks add 10–100ms per request. Set `webhookTimeoutSeconds` appropriately.
6. **Use dry-run before enforce**: `kubectl create --dry-run=server -f pod.yaml` to test against policies.

## Interview Deep Dive

**Q:** What's the difference between a ValidatingWebhookConfiguration and MutatingWebhookConfiguration?

**A:** Mutating webhooks run first and can modify the resource (e.g., inject sidecars, set defaults). Validating webhooks run after and can only accept or reject. Kyverno uses both — mutating for image pull secrets injection, validating for signature checks.

**Q:** Can Kyverno validate images that are already running?

**A:** No. Admission control only applies at resource creation/update time. Running images are not re-verified. To catch drift, combine admission control with a continuous verification tool like Ratify or a cluster scanner (Trivy, Anchore).

**Q:** What happens if the admission webhook is down?

**A:** It depends on `failurePolicy`. If `failurePolicy: Fail`, all pod creations are rejected until the webhook recovers — this can cause cluster-wide outages. If `failurePolicy: Ignore`, pods bypass the policy entirely. Use `Fail` only for critical security policies in production.

**Q:** How do you handle images that are not signed?

**A:** Start by enforcing verification on a single trusted registry (e.g., `private.registry.example.com/*`) while allowing unsigned images from other registries. Phase in by expanding the `imageReferences` list. Use `validationFailureAction: Audit` initially, then switch to `Enforce`.
