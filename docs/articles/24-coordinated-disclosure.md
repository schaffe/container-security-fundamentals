---
title: "Coordinated Vulnerability Disclosure"
section: "CVE Lifecycle"
order: 24
---

# Coordinated Vulnerability Disclosure

Coordinated Vulnerability Disclosure (CVD) is the process by which security researchers, vendors, and users work together to discover, validate, and remediate vulnerabilities before public disclosure. For a Senior Supply Chain Security Engineer at Docker, understanding CVD is essential — Docker's platform touches millions of users, and mishandling a disclosure erodes trust instantly.

## Embargo Period Workflows

The embargo period is the time between a vulnerability being reported to the vendor and its public disclosure. Typical duration is **90 days**, though this varies:

- **Project Zero**: Strict 90-day policy, disclosure after 90 regardless of fix status
- **Docker Security**: Variable embargo, coordinated around patch availability
- **No fixed embargo**: Researcher-controlled, often 30-90 days

### Embargo Timeline

```
Day 0:  Researcher discovers vulnerability
Day 1:  Researcher reports to vendor (security@docker.com)
Day 3:  Vendor acknowledges, assigns internal tracker
Day 7:  Vendor validates, assigns CVE ID
Day 10: Vendor and researcher agree on embargo date
Day 30: Fix developed and tested internally
Day 40: Fix released to downstream distributors (pre-notification)
Day 45: Public disclosure (CVE published, advisory released)
```

### Pre-notification List

During the embargo, vendors share advance details with trusted downstream distributors:

- Linux distributions (RedHat, Debian, Alpine)
- Cloud providers (AWS, GCP, Azure)
- Container runtime maintainers
- Security tool vendors (Aqua, Anchore, Snyk)

This enables coordinated patch release at the disclosure moment. Docker's Security team maintains a pre-notification list for Docker Engine, Docker Desktop, and Docker Scout vulnerabilities.

## Reporter Coordination

### Receiving Reports

Docker's vulnerability reporting process:

```
Email: security@docker.com
PGP key: https://docker.com/.well-known/security.txt
Preferred: GitHub Security Advisory (private report)
```

Key interactions with reporters:

1. **Acknowledgment**: Within 72 hours. "We've received your report."
2. **Validation**: Does the report reproduce? Is it in-scope (Docker Engine, Docker Desktop, Docker Hub, Docker Scout, official images)?
3. **Severity assessment**: Vendor scores CVSS, may differ from researcher's score.
4. **Fix plan**: Agree on embargo date, patch strategy, and disclosure timeline.
5. **Advisory review**: Researcher reviews the draft advisory before publication.
6. **Credit**: Researcher credited in the advisory (unless anonymity requested).

### Disagreement Resolution

Disagreements happen — researcher wants immediate disclosure, vendor needs more time. Common compromises:

- **Partial disclosure**: Publish CVE ID and description but delay technical details
- **Conditional extension**: 14-day extension if vendor demonstrates patch is nearly complete
- **Researcher disclosure**: Researcher may disclose after embargo expires regardless

## Responsible Disclosure vs Full Disclosure

| Aspect | Responsible Disclosure | Full Disclosure |
|--------|----------------------|----------------|
| Embargo | Yes, coordinated | No, immediate |
| Risk | Patches ready before exploit widespread | Users unprotected until emergency patch |
| Researcher risk | Vendor may downplay or ignore | Burned bridges, legal risk |
| Vendor benefit | Controlled messaging, coordinated patches | Zero-day exploited before vendor responds |
| Community benefit | Controlled, measured response | Public pressure forces action |

Docker follows **responsible disclosure** as standard practice, documented at `docker.com/security`. Full disclosure is used only when:
- The vendor ignores a critical vulnerability for 90+ days
- The vulnerability is already being exploited in the wild
- The vendor threatens legal action against the researcher

## Customer Notification

When a vulnerability affects Docker products, customers need to know — but the timing and channel matter.

### Severity-Based Communication

| Severity | Channel | Timing | Content |
|----------|---------|--------|---------|
| Critical | Email + Security advisory + Blog | Same day as fix release | CVE ID, CVSS, affected versions, fixed versions, mitigation steps |
| High | Email + Security advisory | Within 24 hours | Same as critical |
| Medium | Security advisory | Within 1 week | Summary and affected versions |
| Low | Changelog entry | Next release | Brief mention |

### Docker Advisory Template

Docker security advisories follow a consistent format:

```yaml
Advisory ID: DSA-2024-001
CVE: CVE-2024-21626
Title: runc container escape via leaked file descriptors
Severity: Critical (CVSS 8.6)
Affected:
  - docker <= 25.0.0
  - containerd <= 1.7.12
Fixed in:
  - docker 25.0.1
  - containerd 1.7.13
Workarounds:
  - Use --security-opt no-new-privileges
  - Use AppArmor profile blocking mount
Mitigation: Restrict access to Docker socket
Credit: Rory McNamara (Snyk)
Timeline:
  2024-01-10: Reported to Docker Security
  2024-01-15: Validated, CVE-2024-21626 assigned
  2024-01-29: Fix merged, tested
  2024-01-31: Public disclosure
```

## Severity Validation Before Disclosure

Before assigning a CVSS score and disclosing, the vendor must validate:

1. **Reproducibility**: Can we reproduce on latest versions of all affected products?
2. **Scope**: Does this affect Docker Engine, Docker Desktop, Docker Scout, or Docker Hub? Each has different threat models.
3. **Prerequisites**: What privileges, configurations, or conditions are required?
4. **Impact**: Container escape? Denial of service? Information disclosure?
5. **Fix availability**: Can we ship a fix simultaneously?

### Common Validation Pitfalls

- **Partial fix**: A fix that addresses one attack vector but not another. CVE-2024-21626's initial fix prevented `cd` into the host filesystem but didn't block `openat` with `O_DIRECTORY`. Fixed in a follow-up.
- **Downstream-only exploitation**: A vulnerability in Docker Engine may only be exploitable with specific container configurations. Include the configuration requirement in the advisory.
- **Merged CVEs**: Two researchers report the same vulnerability independently. Each gets credit, but one CVE ID is used.

## CVE Assignment

CVE IDs are assigned by **CVE Numbering Authorities (CNAs)**. Docker is a CNA for its own products.

### Docker's CNA Scope

Docker's CNA covers:
- Docker Engine (Moby)
- Docker Desktop
- Docker Hub
- Docker Scout
- Docker Compose
- Docker official images (when Docker controls the image)

### Assignment Process

```bash
# Docker security team requests CVE via MITRE CVE Program
# Or assigns from Docker's reserved block
CVE-2024-XXXXX  # Docker's CVE block
```

Docker must:
1. Reserve the CVE ID during the embargo period
2. Publish the CVE entry to MITRE within 48 hours of public disclosure
3. Provide description, CVSS score, affected versions, and fixed versions
4. Link to the Docker Security Advisory

### Researcher's Role in CVE Assignment

The researcher can request a CVE ID from their own CNA if they find a vulnerability in Docker:
- **First report**: Researcher's CNA assigns the CVE ID
- **Independent discovery**: Two CNAs may assign different IDs; the CVE program merges them
- **Duplicate**: If Docker already has a CVE assigned, the researcher's CNA should reference the existing CVE

## Interview Scenario

You'll likely be asked: "A researcher finds a critical container escape in Docker Engine and wants to disclose immediately. How do you handle this?"

**Expected answer structure**:

1. **Acknowledge and thank** the researcher within hours. Never let a researcher feel ignored.
2. **Validate the report** internally. Does it reproduce? What's the attack scenario?
3. **Propose an embargo** with concrete dates. Explain why Docker needs time to patch (distribution, testing, customer notification).
4. **If the researcher insists on immediate disclosure**, negotiate a compromise:
   - Publish the CVE ID and severity, but delay technical details for 7-14 days
   - Or accept the disclosure and shift to customer notification mode immediately
5. **Prepare the advisory** with workarounds so customers have options even without a patch.
6. **Post-disclosure**: Ensure the researcher is credited. Retrospective review to improve Docker's vulnerability response process.

The key principle: **Respect the researcher's timeline while protecting customers**. A rushed disclosure without a fix helps nobody. A delayed disclosure that ignores the researcher harms trust. CVD is the middle path.

## Docker's security.txt

Docker's vulnerability disclosure policy is published at the standard location:

```
$ curl https://docker.com/.well-known/security.txt
Contact: mailto:security@docker.com
Encryption: https://docker.com/.well-known/pgp-key.txt
Acknowledgments: https://docker.com/security/hall-of-fame
Policy: https://docker.com/security
Hiring: https://docker.com/careers
Preferred-Languages: en
```

This is the first place a security researcher looks. Every Docker engineer should know it exists and how the process works.
