---
title: "CVSS and EPSS for Vulnerability Prioritization"
section: "CVE Lifecycle"
order: 22
---

# CVSS and EPSS for Vulnerability Prioritization

Not all CVEs are equal. A Critical-severity CVE in a library not exposed to untrusted input is less urgent than a Medium-severity CVE in your authentication service. Understanding CVSS and EPSS — and their limitations — is essential for defending prioritization decisions to customers and leadership.

## CVSS v3.1 Base Score

CVSS 3.1 Base Score is computed from eight metrics across three groups:

### Exploitability Metrics (how easy is it to exploit?)

| Metric | Abbr | Values | Example: CVE-2024-21626 |
|--------|------|--------|------------------------|
| Attack Vector | AV | Network (0.85), Adjacent (0.62), Local (0.55), Physical (0.20) | AV:L (requires local access via container) |
| Attack Complexity | AC | Low (0.77), High (0.44) | AC:L (no special conditions) |
| Privileges Required | PR | None (0.85), Low (0.62), High (0.27) | PR:L (attacker needs low-privilege container) |
| User Interaction | UI | None (0.85), Required (0.62) | UI:N (no user action needed) |

### Impact Metrics (what's the damage?)

| Metric | Abbr | Values | Example |
|--------|------|--------|---------|
| Confidentiality | C | High (0.56), Low (0.22), None (0) | C:H (full host access) |
| Integrity | I | High (0.56), Low (0.22), None (0) | I:H (write to host filesystem) |
| Availability | A | High (0.56), Low (0.22), None (0) | A:H (deny host services) |

### Scoring Formula (simplified)

Scoring is not linear — it uses an equation that weights impact over exploitability:

```
Exploitability  = 8.22 × AV × AC × PR × UI
Impact          = 6.42 × (1 - (1 - C) × (1 - I) × (1 - A))
Base Score      = min(10, truncate(1.08 × (Impact + Exploitability)))
```

For CVE-2024-21626 (AV:L/AC:L/PR:L/UI:N/C:H/I:H/A:H):

```
Exploitability = 8.22 × 0.55 × 0.77 × 0.62 × 0.85 = 1.78
Impact         = 6.42 × (1 - (1 - 0.56)³) = 6.42 × 0.914 = 5.87
Base Score     = min(10, 1.08 × (1.78 + 5.87)) = 8.26 → 8.6 (HIGH)
```

### Temporal and Environmental Scores

**Temporal Score** adjusts for real-world factors:
- `E` (Exploit Code Maturity): Not Defined (1.0), Unproven (0.91), Proof-of-Concept (0.94), Functional (0.97), High (1.0)
- `RL` (Remediation Level): Official Fix (0.95), Temporary Fix (0.96), Workaround (0.97), Unavailable (1.0)
- `RC` (Report Confidence): Unknown (0.92), Reasonable (0.96), Confirmed (1.0)

**Environmental Score** adjusts for your specific deployment:
- Modified Base Metrics (same formula, tailored to your environment)
- CIA Requirements: Low/Medium/High (weights 0.5/1.0/1.5)

## CVSS 4.0 Changes

CVSS 4.0 (released November 2023) introduces:

- **Attack Requirements (AT)**: New metric capturing deployment-dependent conditions. Present (0.44) vs None (0.77). A vuln affecting only multi-tenant systems would have AT:Present.
- **Safety (S)**: Identifies vulnerabilities affecting physical safety (e.g., medical devices, industrial control). S:Present adds weight.
- **Automatable (AU)**: Is the attack automatable at scale? Replaces the old "Exploit Code Maturity." Automatable (0.63) vs Not (1.0).
- **Recovery (R)**: How resilient is the system? Automatic (1.0), User (0.95), Irrecoverable (1.0+).
- **Vulnerability Response Effort (RE)**: How hard is it to remediate? Focused (1.0), Partial (0.95), Diffuse (0.94).

CVSS 4.0 eliminates Temporal and Environmental groups — those concerns are now embedded in the supplemental metrics.

```bash
# Example CVSS 4.0 vector
CVSS:4.0/AV:L/AC:L/AT:N/PR:L/UI:N/VC:H/VI:H/VA:H/SC:H/SI:H/SA:H/AU:N/S:N/R:A/RE:F
```

## EPSS (Exploit Prediction Scoring System)

EPSS is a **probability score** (0-1) predicting whether a CVE will be exploited in the next 30 days. It uses machine learning trained on CVE metadata, exploit chatter, and weaponization patterns.

```
EPSS score: 0.04237  (≈4.24% probability of exploitation in next 30 days)
EPSS percentile: 0.87940  (higher than 87.94% of all CVEs)
```

### EPSS vs CVSS

| Dimension | CVSS | EPSS |
|-----------|------|------|
| Measures | Severity (intrinsic) | Exploitation likelihood (real-world) |
| Scale | 0-10 ordinal | 0-1 probability |
| Updates | Fixed per NVD | Updated daily |
| Data sources | Expert assessment | ML on >10K features |
| Use case | Compliance baseline | Operational triage |

## Combining CVSS + EPSS for Prioritization

A common framework is a **risk matrix**:

```
Priority = Severity × Likelihood
```

| CVSS Severity | EPSS < 0.01 | EPSS 0.01-0.1 | EPSS > 0.1 |
|---------------|-------------|---------------|------------|
| Critical (9.0-10.0) | P1 (7d) | P0 (24h) | P0 (immediate) |
| High (7.0-8.9) | P2 (30d) | P1 (7d) | P0 (24h) |
| Medium (4.0-6.9) | P3 (90d) | P2 (30d) | P1 (7d) |
| Low (0.1-3.9) | P4 (backlog) | P3 (90d) | P2 (30d) |

### Common Mistakes

1. **Equating CVSS severity with urgency**: A Critical CVSS vuln with EPSS 0.0001 is unlikely to be exploited. Conversely, CVE-2023-44487 (HTTP/2 Rapid Reset) had only CVSS 7.5 (High) but EPSS 0.97 — it was exploited at massive scale within days.

2. **Ignoring Environmental score**: A CVE that requires local access (AV:L) is Critical on a multi-tenant SaaS platform but Low on a single-user workstation. Default CVSS scores are often inappropriate for your deployment context.

3. **Treating CVSS as static**: NVD updates scores. CVE-2024-3094 (xz backdoor) started as CVSS 7.5 but was revised to 10.0 when the full scope was understood. Always check the latest score.

4. **Ignoring fix availability**: A Critical CVE with no fix available is a fundamentally different risk than one with a one-line patch. Remediation should consider both score and remediation feasibility.

### Practical Prioritization at Docker

```bash
# Docker Scout with EPSS enrichment
docker scout cves alpine:latest \
  --epss-threshold 0.05 \
  --only-fixed \
  --severity critical,high
```

For Docker's container ecosystem, the highest-priority CVEs are:
- **CVSS ≥ 7.0 + EPSS ≥ 0.05 + fix available**: Immediate patch
- **CVSS ≥ 9.0 + EPSS < 0.01 + fix available**: Patch within 30 days
- **CVSS ≥ 7.0 + EPSS ≥ 0.05 + no fix**: Mitigate at runtime (seccomp, AppArmor, read-only rootfs)
- **CVSS < 7.0 + EPSS < 0.01**: Accept or schedule for next maintenance

In interviews, emphasize that CVSS tells you **worst-case impact** while EPSS tells you **real-world probability**. Combined, they give you **risk**. Neither alone is sufficient for operational prioritization.
