---
title: "Pod Security Standards (PSS)"
section: "Helm Chart Security Adaptation"
order: 17
---

# Pod Security Standards (PSS)

Pod Security Standards (PSS) define three policy levels that restrict pod behavior based on security best practices. They replaced PodSecurityPolicy (PSP), which was deprecated in K8s 1.21 and removed in 1.25. PSS is enforced via Pod Security Admission (PSA), a built-in admission controller.

## The Three Policy Levels

### Privileged

Unrestricted. Allows everything. Intended for system-level and infrastructure workloads (e.g., cluster CNI daemonsets, storage drivers, monitoring agents).

**What it allows:**
- Privileged containers
- All capabilities
- Host network, PID, IPC
- Host port ranges
- HostPath volumes
- Running as root
- SELinux custom options
- Any seccomp profile

### Baseline

Prevents known privilege escalations. Intended for general-purpose workloads that don't require special privileges.

**What it blocks:**

| Restriction | Detail |
|---|---|
| `privileged: true` | Privileged containers disallowed |
| Host namespaces | `hostPID`, `hostIPC`, `hostNetwork` disallowed |
| Host ports | Most host port ranges blocked (exceptions below) |
| Linux capabilities | `add` capability list restricted; `drop` is fine |
| `seccomp` | Must be set; type `Unconfined` is allowed |
| `SYS_ADMIN` capability | Blocked |
| HostPath volumes | Disallowed |
| AppArmor | Must be `runtime/default` or local |
| SELinux `type` | Must be unset or `container_t` |
| [`/proc` mount type](../linux-fundamentals/proc-container-isolation.md#procmount-in-kubernetes) | Must be `DefaultProcMount` |
| Sysctls | Only `net.ipv4.ip_local_port_range`, `net.ipv4.ping_group_range`, and `net.ipv4.ip_unprivileged_port_start` allowed |
| Windows HostProcess | Disallowed |

**Allowable host ports:** Ports 1024 and above on hostNetwork are generally allowed under Baseline; exact behavior depends on implementation nuances.

### Restricted

Hardened for security-critical workloads. Meets Pod Security Standards toughest requirements.

**Inherits all Baseline restrictions, plus:**

| Restriction | Detail |
|---|---|
| `runAsNonRoot: true` | Must be set; image must not run as root |
| `runAsUser` | Must not be 0 (root). Must specify a range (not `RunAsAny`) |
| `seccomp` | Must be `RuntimeDefault` or `Localhost` |
| `capabilities.drop` | Must drop `ALL` |
| `allowPrivilegeEscalation` | Must be `false` |

## Pod Security Admission (PSA)

PSA is a built-in admission controller (enabled by default in K8s 1.23+, GA in 1.25). It evaluates pods against the three PSS levels using **labels on namespaces**.

### Modes

| Mode | Behavior |
|---|---|
| **enforce** | Rejects pod creation that violates the policy |
| **audit** | Allows the pod but logs a violation in audit records |
| **warn** | Allows the pod but returns a warning to the API user |

### Namespace Label Schema

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: production
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: baseline
    pod-security.kubernetes.io/warn: restricted
```

The `enforce`, `audit`, and `warn` labels can differ for the same namespace, enabling a gradual rollout:

1. Start with `warn` to surface violations.
2. Move to `audit` to log without impact.
3. Graduate to `enforce` once all workloads are compliant.

### Versioning

```yaml
labels:
  pod-security.kubernetes.io/enforce-version: v1.28
```

Pins the policy checks to a specific K8s version's standard, preventing new checks from breaking existing workloads on upgrade.

### Exemptions

Namespaces can be exempted via kube-apiserver flags:

```yaml
--pod-security-admission-config-file=/etc/kubernetes/pss-config.yaml
```

The config file specifies exempt namespaces, runtimes, and users.

```yaml
apiVersion: apiserver.config.k8s.io/v1
kind: AdmissionConfiguration
plugins:
  - name: PodSecurity
    configuration:
      exemptions:
        namespaces: ["kube-system", "gatekeeper-system"]
        runtimes: ["gvisor", "kata"]
```

## Migration Guide: PSP to PSS

### Step 1: Audit Current Permissions

```bash
# What PSPs exist already
kubectl get psp --all-namespaces

# Who uses them
kubectl get rolebinding,clusterrolebinding --all-namespaces -o json \
  | jq '.items[] | select(.roleRef.name | startswith("psp:"))'
```

### Step 2: Identify In-Use PSPs

PodSecurityPolicies use `privileged`, `baseline`, and `restricted` tiers internally. Map each PSP:

| PSP | PSS Equivalent |
|---|---|
| `privileged` | `privileged` |
| `nonroot` | `restricted` |
| `restricted` | `restricted` |
| `baseline` | `baseline` |

### Step 3: Enable PSA with Audit-Only

Label all namespaces with the appropriate PSS level in `audit` and `warn` mode first:

```bash
for ns in $(kubectl get ns -o name | cut -d/ -f2); do
  kubectl label ns "$ns" \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite
done
```

### Step 4: Fix Violations

Check violations:

```bash
kubectl get events -A --field-selector reason=FailedCreate \
  | grep "violates PodSecurity"
```

Common fixes:
- Drop unused capabilities
- Set `runAsNonRoot: true`
- Remove `privileged: true` (use individual capabilities instead)
- Replace `hostNetwork` with proper network policies
- Set `seccompProfile: RuntimeDefault`

### Step 5: Gate with Exemptions

Switch to `enforce` mode, keeping exemptions for system namespaces:

```bash
kubectl label ns production \
  pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/enforce-version=v1.28
```

### Step 6: Remove PSPs

Once migration is complete:

```bash
kubectl delete psp --all
```

## PSA in Helm

To make charts PSS-compatible, conditionally render security contexts:

```yaml
# In values.yaml
podSecurityContext:
  runAsNonRoot: true
  runAsUser: 1001
  fsGroup: 2000
  seccompProfile:
    type: RuntimeDefault

containerSecurityContext:
  allowPrivilegeEscalation: false
  readOnlyRootFilesystem: true
  capabilities:
    drop: ["ALL"]
```

```yaml
# In deployment template
spec:
  securityContext:
    {{- toYaml .Values.podSecurityContext | nindent 4 }}
  containers:
    - name: {{ .Chart.Name }}
      securityContext:
        {{- toYaml .Values.containerSecurityContext | nindent 10 }}
```

## Interview Deep Dive

**Q:** Why was PSP removed?

**A:** PSP had fundamental design issues: it was a single `ClusterRole` resource with mutate-on-create semantics that made it impossible to audit without webhook tooling. The CRD validation was incomplete, and the API never graduated from beta. PSS+PSA replaced it with a simpler label-based approach that integrates with the built-in admission controller.

**Q:** Can you use both PSP and PSA during migration?

**A:** Yes. PSP and PSA can run in parallel. PSA evaluates independently of PSP. During migration, run PSA in `audit`/`warn` mode while PSPs still enforce. This avoids enforcement gaps.

**Q:** What about `ephemeralContainers` and `initContainers`?

**A:** PSA evaluates both `initContainers` and `ephemeralContainers` under the same policy. Init containers are checked at pod creation; ephemeral containers are checked at attach time. Both must satisfy the namespace's PSS level.
